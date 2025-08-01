# Copyright 2025 Mattia Giambirtone & All Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import heimdall/eval
import heimdall/board
import heimdall/movegen
import heimdall/util/see
import heimdall/util/logs
import heimdall/util/limits
import heimdall/util/shared
import heimdall/util/aligned
import heimdall/util/tunables
import heimdall/transpositions


import std/math
import std/times
import std/options
import std/atomics
import std/strutils
import std/monotimes
import std/strformat
import std/heapqueue


export shared

# Miscellaneous parameters that are not meant to be tweaked (neither manually nor automatically)
const

    # How many killer moves we keep track of
    NUM_KILLERS* = 1

    # Constants used during move ordering

    MVV_MULTIPLIER = 10
    # These offsets are used in the move
    # ordering step to ensure moves from
    # different heuristics don't have
    # overlapping scores. Heuristics with
    # higher offsets will always be placed
    # first
    TTMOVE_OFFSET = 700_000
    GOOD_CAPTURE_OFFSET = 600_000
    KILLERS_OFFSET = 500_000
    COUNTER_OFFSET = 400_000
    QUIET_OFFSET = 200_000
    BAD_CAPTURE_OFFSET = 50_000

    # Max value for scores in our
    # history tables
    HISTORY_SCORE_CAP = 16384


# Both the depth and move number are one-indexed, and it's cheaper to have an extra
# entry in the array than to do min(thing, maxsize)
func computeLMRTable: array[MAX_DEPTH + 1, array[MAX_MOVES + 1, int]] {.compileTime.} =
    ## Precomputes the table containing reduction offsets at compile
    ## time
    for i in 1..result.high():
        for j in 1..result[0].high():
            result[i][j] = round(0.8 + ln(i.float) * ln(j.float) * 0.4).int


const LMR_TABLE = computeLMRTable()


type
    ThreatHistory* = array[White..Black, array[Square(0)..Square(63), array[Square(0)..Square(63), array[bool, array[bool, int16]]]]]
    CaptureHistory* = array[White..Black, array[Square(0)..Square(63), array[Square(0)..Square(63), array[Pawn..Queen, array[bool, array[bool, int16]]]]]]
    CounterMoves* = array[Square(0)..Square(63), array[Square(0)..Square(63), Move]]
    KillerMoves* = array[MAX_DEPTH, array[NUM_KILLERS, Move]]
    ContinuationHistory* = array[White..Black, array[PieceKind.Pawn..PieceKind.King,
                           array[Square(0)..Square(63), array[White..Black, array[PieceKind.Pawn..PieceKind.King,
                           array[Square(0)..Square(63), int16]]]]]]

    SearchStackEntry = object
        ## An entry containing metadata
        ## about a ply of search

        # The static eval at the ply this
        # entry was created at
        staticEval: Score
        # The move made to reach this ply
        move: Move
        # The piece that moved in this ply
        piece: Piece
        # Whether the side to move in the
        # position in this ply was in check
        inCheck: bool
        # The value returned by getReduction()
        # for this ply
        reduction: int

    SearchStack = array[MAX_DEPTH + 1, SearchStackEntry]
        ## Stores information about each
        ## ply of the search

    MoveType = enum
        HashMove,
        GoodNoisy,
        KillerMove,
        CounterMove,
        QuietMove,
        BadNoisy

    ScoredMove = tuple[move: Move, data: int32]

    SearchManager* = object
        # Public search state
        state*: SearchState
        # Search stack. Stores per-ply metadata
        stack: SearchStack
        # Search statistics for this thread
        statistics*: SearchStatistics
        # Handles logging 
        logger: SearchLogger
        # Constrains the search according to
        # configured limits
        limiter*: SearchLimiter
        # The set of parameters used by the
        # search
        parameters*: SearchParameters
        # Chessboard where we play moves
        board: Chessboard
        # Only search these root moves
        searchMoves: seq[Move]
        # Transposition table
        transpositionTable: ptr TTable
        # Heuristic tables
        quietHistory: ptr ThreatHistory
        captureHistory: ptr CaptureHistory
        killers: ptr KillerMoves
        counters: ptr CounterMoves
        continuationHistory: ptr ContinuationHistory
        # Internal state that doesn't need to be exposed

        workerPool: WorkerPool
        # How many extra workers to search with, along with
        # the main search thread
        workerCount: int
        # The set of principal variations for each ply
        # of the search. We keep one extra entry so we
        # don't need any special casing inside the search
        # function when constructing pv lines
        pvMoves: array[MAX_DEPTH + 1, array[MAX_DEPTH + 1, Move]]
        # The persistent evaluation state needed
        # for NNUE
        evalState: EvalState
        # Has the internal clock been started yet?
        clockStarted: bool
        # Has a call to limiter.expired() returned
        # true before? This allows us to avoid re-
        # checking for time once a limit expires
        expired: bool
        # The minimum ply where NMP will be enabled again.
        # This is needed for NMP verification search
        minNmpPly: int
        # Used for accurate score reporting when search
        # is cancelled mid-way
        previousScores*: array[MAX_MOVES, Score]
        previousLines*: array[MAX_MOVES, array[MAX_DEPTH + 1, Move]]
        # Static, white-relative contempt, set via UCI
        contempt: Score

    # Unfortunately due to recursive dependency issues we have
    # to implement the worker pool here

    WorkerCommandType = enum
        Shutdown, Reset, Setup, Go, Ping
    
    WorkerCommand = object
        case kind: WorkerCommandType
            of Go:
                searchMoves: seq[Move]
                variations: int
            else:
                discard
    
    WorkerResponse = enum
        Ok, SetupMissing, SetupAlready, NotSetUp, Pong

    SearchWorker* = ref object
        ## An individual worker thread
        workerId: int
        thread: Thread[SearchWorker]
        manager: SearchManager
        channels: tuple[command: Channel[WorkerCommand], response: Channel[WorkerResponse]]
        isSetUp: Atomic[bool]
        # All the heuristic tables and other state 
        # to be passed to the search manager created
        # at worker setup
        evalState: EvalState   # Creating this from scratch every time is VERY slow
        positions: seq[Position]
        transpositionTable: ptr TTable
        quietHistory: ptr ThreatHistory
        captureHistory: ptr CaptureHistory
        killers: ptr KillerMoves
        counters: ptr CounterMoves
        continuationHistory: ptr ContinuationHistory
        parameters: SearchParameters
    
    WorkerPool* = object
        workers: seq[SearchWorker]


func resetHeuristicTables*(quietHistory: ptr ThreatHistory, captureHistory: ptr CaptureHistory, killerMoves: ptr KillerMoves,
                           counterMoves: ptr CounterMoves, continuationHistory: ptr ContinuationHistory) =
    ## Resets all the heuristic tables to their default configuration
    
    for color in White..Black:
        for i in Square(0)..Square(63):
            for j in Square(0)..Square(63):
                quietHistory[color][i][j][true][false] = 0
                quietHistory[color][i][j][false][true] = 0
                quietHistory[color][i][j][true][true] = 0
                quietHistory[color][i][j][false][false] = 0
                for piece in Pawn..Queen:
                    captureHistory[color][i][j][piece][true][false] = 0
                    captureHistory[color][i][j][piece][false][true] = 0
                    captureHistory[color][i][j][piece][true][true] = 0
                    captureHistory[color][i][j][piece][false][false] = 0
    for i in 0..<MAX_DEPTH:
        for j in 0..<NUM_KILLERS:
            killerMoves[i][j] = nullMove()
    for fromSq in Square(0)..Square(63):
        for toSq in Square(0)..Square(63):
            counterMoves[fromSq][toSq] = nullMove()
    for sideToMove in White..Black:
        for piece in PieceKind.all():
            for to in Square(0)..Square(63):
                for prevColor in White..Black:
                    for prevPiece in PieceKind.all():
                        for prevTo in Square(0)..Square(63):
                            continuationHistory[sideToMove][piece][to][prevColor][prevPiece][prevTo] = 0


func score(self: ScoredMove): int32 {.inline.} = self.data and 0xffffff
func stage(self: ScoredMove): MoveType {.inline.} = MoveType(self.data shr 24)


proc search*(self: var SearchManager, searchMoves: seq[Move] = @[], silent=false, ponder=false, minimal=false, variations=1): seq[array[MAX_DEPTH + 1, Move]] {.gcsafe.}
proc setBoardState*(self: SearchManager, state: seq[Position]) {.gcsafe.}
func createWorkerPool: WorkerPool =
    discard



proc newSearchManager*(positions: seq[Position], transpositions: ptr TTable,
                       quietHistory: ptr ThreatHistory, captureHistory: ptr CaptureHistory,
                       killers: ptr KillerMoves, counters: ptr CounterMoves,
                       continuationHistory: ptr ContinuationHistory,
                       parameters=getDefaultParameters(), mainWorker=true, chess960=false,
                       evalState=newEvalState(), state=newSearchState(),
                       statistics=newSearchStatistics(), normalizeScore: bool = true): SearchManager {.gcsafe.} =
    ## Initializes a new search manager
    result = SearchManager(transpositionTable: transpositions, quietHistory: quietHistory,
                           captureHistory: captureHistory, killers: killers, counters: counters,
                           continuationHistory: continuationHistory, parameters: parameters,
                           state: state, statistics: statistics, evalState: evalState)
    new(result.board)
    result.state.normalizeScore.store(normalizeScore)
    result.state.chess960.store(chess960)
    result.state.isMainThread.store(mainWorker)
    result.limiter = newSearchLimiter(result.state, result.statistics)
    result.logger = createSearchLogger(result.state, result.statistics, result.board, transpositions)
    result.workerPool = createWorkerPool()
    result.setBoardState(positions)


proc workerLoop(self: SearchWorker) {.thread.} =
    while true:
        let msg = self.channels.command.recv()
        case msg.kind:
            of Ping:
                self.channels.response.send(Pong)
            of Shutdown:
                if self.isSetUp.load():
                    self.isSetUp.store(false)
                    freeHeapAligned(self.killers)
                    freeHeapAligned(self.quietHistory)
                    freeHeapAligned(self.captureHistory)
                    freeHeapAligned(self.continuationHistory)
                    freeHeapAligned(self.counters)
                self.channels.response.send(Ok)
                break
            of Reset:
                if not self.isSetUp.load():
                    self.channels.response.send(NotSetUp)
                    continue

                resetHeuristicTables(self.quietHistory, self.captureHistory, self.killers, self.counters, self.continuationHistory)
                self.channels.response.send(Ok)
            of Go:
                # Start a search
                if not self.isSetUp.load():
                    self.channels.response.send(SetupMissing)
                    continue
                self.channels.response.send(Ok)
                discard self.manager.search(msg.searchMoves, true, false, false, msg.variations)
            of Setup:
                if self.isSetUp.load():
                    self.channels.response.send(SetupAlready)
                    continue
                # Allocate on 64-byte boundaries to ensure threads won't have
                # overlapping stuff in their cache lines
                self.quietHistory = allocHeapAligned(ThreatHistory, 64)
                self.continuationHistory = allocHeapAligned(ContinuationHistory, 64)
                self.captureHistory = allocHeapAligned(CaptureHistory, 64)
                self.killers = allocHeapAligned(KillerMoves, 64)
                self.counters = allocHeapAligned(CounterMoves, 64)
                self.isSetUp.store(true)
                self.manager = newSearchManager(self.positions, self.transpositionTable,
                                                self.quietHistory, self.captureHistory,
                                                self.killers, self.counters, self.continuationHistory,
                                                self.parameters, false, false, self.evalState)
                self.channels.response.send(Ok)


proc cmd(self: SearchWorker, cmd: WorkerCommand, expected: WorkerResponse = Ok) {.inline.} =
    self.channels.command.send(cmd)
    let response = self.channels.response.recv()
    doAssert response == expected, &"sent {cmd} to worker #{self.workerId} and expected {expected}, got {response} instead"


func simpleCmd(kind: WorkerCommandType): WorkerCommand {.inline.} = WorkerCommand(kind: kind)


proc ping(self: SearchWorker) {.inline.} =
    self.cmd(simpleCmd(Ping), Pong)


proc setup(self: SearchWorker) {.inline.} =
    self.cmd(simpleCmd(Setup))


proc go(self: SearchWorker, searchMoves: seq[Move], variations: int) {.inline.} =
    self.cmd(WorkerCommand(kind: Go, searchMoves: searchMoves, variations: variations))


proc shutdown(self: SearchWorker) {.inline.} =
    self.cmd(simpleCmd(Shutdown))
    joinThread(self.thread)
    self.channels.command.close()
    self.channels.response.close()


proc reset(self: SearchWorker) {.inline.} =
    self.cmd(simpleCmd(Reset))


proc create(self: var WorkerPool): SearchWorker {.inline, discardable.} =
    ## Starts up a new thread and readies it to begin
    ## searching when necessary
    result = SearchWorker(workerId: self.workers.len())
    self.workers.add(result)
    result.channels.command.open(0)
    result.channels.response.open(0)
    createThread(result.thread, workerLoop, result)
    # Ensure worker is alive
    result.ping()


proc reset(self: WorkerPool) {.inline.} =
    ## Resets the state of all worker threads, but
    ## keeps them alive to be reused
    for worker in self.workers:
        worker.reset()


proc shutdown(self: var WorkerPool) {.inline.} =
    ## Cleanly shuts down all the threads in the
    ## pool
    for worker in self.workers:
        worker.shutdown()
    self.workers.setLen(0)


proc setupWorkers(self: var SearchManager) {.inline.} =
    ## Setups each search worker by copying in the necessary
    ## data from the main searcher
    for i in 0..<self.workerCount:
        var worker = self.workerPool.workers[i]
        # This is the only stuff that we pass from the outside
        worker.positions = self.board.positions.deepCopy()
        worker.evalState = self.evalState.deepCopy()
        worker.parameters = self.parameters
        worker.transpositionTable = self.transpositionTable
        # Keep track of worker statistics
        # This will allocate all the internal data structures for
        # the worker
        worker.setup()
        self.state.childrenStats.add(worker.manager.statistics)


proc createWorkers(self: var SearchManager, workerCount: int) {.inline.} =
    ## Creates the specified number of workers
    for i in 0..<workerCount:
        self.workerPool.create()
    self.setupWorkers()


proc shutdownWorkers*(self: var SearchManager) {.inline.} =
    self.workerPool.shutdown()
    self.state.childrenStats.setLen(0)


proc resetWorkers*(self: var SearchManager) {.inline.} =
    ## Resets the state of all worker threads but does
    ## not shut them down. Heuristic tables are reset
    ## to their default configuration and not aligned
    ## with the main searcher
    self.workerPool.reset()


proc restartWorkers*(self: var SearchManager) {.inline.} =
    ## Cleanly shuts down all the workers and
    ## restarts them from scratch
    self.shutdownWorkers()
    self.createWorkers(self.workerCount)


proc startSearch(self: WorkerPool, searchMoves: seq[Move], variations: int) {.inline.} =
    for worker in self.workers:
        worker.go(searchMoves, variations)


proc setWorkerCount*(self: var SearchManager, workerCount: int) {.inline.} =
    ## Sets the number of additional worker threads to search
    ## alongside the main thread
    doAssert workerCount >= 0
    if workerCount != self.workerCount:
        self.workerCount = workerCount
        self.shutdownWorkers()
        self.createWorkers(self.workerCount)


func getWorkerCount*(self: SearchManager): int {.inline.} = self.workerCount

func setContempt*(self: var SearchManager, value: Score) {.inline.} =
    self.contempt = value

proc setBoardState*(self: SearchManager, state: seq[Position]) {.gcsafe.} =
    ## Sets the board state for the search
    self.board.positions.setLen(0)
    for position in state:
        self.board.positions.add(position.clone())
    self.evalState.init(self.board)
    for worker in self.workerPool.workers:
        worker.manager.setBoardState(state)


func getCurrentPosition*(self: SearchManager): lent Position {.inline.} =
    ## Returns the latest position stored in the
    ## manager's board state
    return self.board.position


proc setNetwork*(self: var SearchManager, path: string) =
    ## Loads the network at the given path into the
    ## search manager
    self.evalState = newEvalState(path)
    self.evalState.init(self.board)
    # newEvalState and init() are expensive, no
    # need to run them for every thread!
    for worker in self.workerPool.workers:
        worker.manager.evalState = self.evalState.deepCopy()


proc setUCIMode*(self: SearchManager, value: bool) =
    self.state.uciMode.store(value)


func isSearching*(self: SearchManager): bool {.inline.} =
    ## Returns whether a search for the best
    ## move is in progress
    result = self.state.searching.load()


func stop*(self: SearchManager) {.inline.} =
    ## Stops the search if it is
    ## running
    self.state.stop.store(true)
    # Stop all worker threads
    for child in self.workerPool.workers:
        child.manager.stop()


func isKillerMove(self: SearchManager, move: Move, ply: int): bool {.inline.} =
    ## Returns whether the given move is a killer move
    for killer in self.killers[ply]:
        if killer == move:
            return true


proc getMainHistScore(self: SearchManager, sideToMove: PieceColor, move: Move): int16 {.inline.} =
    ## Returns the score for the given move and side to move
    ## in our main history tables (threathist/capthist)
    assert move.isCapture() or move.isQuiet()
    let startAttacked = self.board.position.threats.contains(move.startSquare)
    let targetAttacked = self.board.position.threats.contains(move.targetSquare)
    if move.isQuiet():
        result = self.quietHistory[sideToMove][move.startSquare][move.targetSquare][startAttacked][targetAttacked]
    else:
        let victim = self.board.getPiece(move.targetSquare).kind
        result = self.captureHistory[sideToMove][move.startSquare][move.targetSquare][victim][startAttacked][targetAttacked]


func getOnePlyContHistScore(self: SearchManager, sideToMove: PieceColor, piece: Piece, target: Square, ply: int): int16 {.inline.} =
    ## Returns the score stored in the continuation history 1
    ## ply ago, with the given piece and target square. The ply
    ## argument is intended as the current distance from root,
    ## NOT the previous ply
    var prevPiece = self.stack[ply - 1].piece
    result += self.continuationHistory[sideToMove][piece.kind][target][prevPiece.color][prevPiece.kind][self.stack[ply - 1].move.targetSquare]


func getTwoPlyContHistScore(self: SearchManager, sideToMove: PieceColor, piece: Piece, target: Square, ply: int): int16 {.inline.} =
    ## Returns the score stored in the continuation history 2
    ## plies ago, with the given piece and target square. The ply
    ## argument is intended as the current distance from root,
    ## NOT the previous ply
    var prevPiece = self.stack[ply - 2].piece
    result += self.continuationHistory[sideToMove][piece.kind][target][prevPiece.color][prevPiece.kind][self.stack[ply - 2].move.targetSquare]


func getFourPlyContHistScore(self: SearchManager, sideToMove: PieceColor, piece: Piece, target: Square, ply: int): int16 {.inline.} =
    ## Returns the score stored in the continuation history 4
    ## plies ago, with the given piece and target square. The ply
    ## argument is intended as the current distance from root,
    ## NOT the previous ply
    var prevPiece = self.stack[ply - 4].piece
    result += self.continuationHistory[sideToMove][piece.kind][target][prevPiece.color][prevPiece.kind][self.stack[ply - 4].move.targetSquare]


func getContHistScore(self: SearchManager, sideToMove: PieceColor, piece: Piece, target: Square, ply: int): Score {.inline.} =
    ## Returns the continuation history score for as many
    ## plies as possible. This is the only function that
    ## performs ply checks to make sure no OOB access occurs
    if ply > 0:
        result += self.getOnePlyContHistScore(sideToMove, piece, target, ply)
    if ply > 1:
        result += self.getTwoPlyContHistScore(sideToMove, piece, target, ply)
    if ply > 3:
        result += self.getFourPlyContHistScore(sideToMove, piece, target, ply)


proc updateHistories(self: SearchManager, sideToMove: PieceColor, move: Move, piece: Piece, depth, ply: int, good: bool) {.inline.} =
    ## Updates internal histories with the given move
    ## which failed, at the given depth and ply from root,
    ## either high or low depending on whether good
    ## is true or false
    assert move.isCapture() or move.isQuiet()
    let startAttacked = self.board.position.threats.contains(move.startSquare)
    let targetAttacked = self.board.position.threats.contains(move.targetSquare)
    if move.isQuiet():
        let bonus = (if good: self.parameters.moveBonuses.quiet.good else: -self.parameters.moveBonuses.quiet.bad) * depth
        if ply > 0 and not self.board.positions[^2].fromNull:
            let prevPiece = self.stack[ply - 1].piece
            self.continuationHistory[sideToMove][piece.kind][move.targetSquare][prevPiece.color][prevPiece.kind][self.stack[ply - 1].move.targetSquare] += (bonus - abs(bonus) * self.getOnePlyContHistScore(sideToMove, piece, move.targetSquare, ply) div HISTORY_SCORE_CAP).int16
        if ply > 1 and not self.board.positions[^3].fromNull:
          let prevPiece = self.stack[ply - 2].piece
          self.continuationHistory[sideToMove][piece.kind][move.targetSquare][prevPiece.color][prevPiece.kind][self.stack[ply - 2].move.targetSquare] += (bonus - abs(bonus) * self.getTwoPlyContHistScore(sideToMove, piece, move.targetSquare, ply) div HISTORY_SCORE_CAP).int16
        if ply > 3 and not self.board.positions[^5].fromNull:
          let prevPiece = self.stack[ply - 4].piece
          self.continuationHistory[sideToMove][piece.kind][move.targetSquare][prevPiece.color][prevPiece.kind][self.stack[ply - 4].move.targetSquare] += (bonus - abs(bonus) * self.getFourPlyContHistScore(sideToMove, piece, move.targetSquare, ply) div HISTORY_SCORE_CAP).int16

        self.quietHistory[sideToMove][move.startSquare][move.targetSquare][startAttacked][targetAttacked] += int16(bonus - abs(bonus) * self.getMainHistScore(sideToMove, move) div HISTORY_SCORE_CAP)

    elif move.isCapture():
        let bonus = (if good: self.parameters.moveBonuses.capture.good else: -self.parameters.moveBonuses.capture.bad) * depth
        let victim = self.board.getPiece(move.targetSquare).kind
        # We use this formula to evenly spread the improvement the more we increase it (or decrease it)
        # while keeping it constrained to a maximum (or minimum) value so it doesn't (over|under)flow.
        self.captureHistory[sideToMove][move.startSquare][move.targetSquare][victim][startAttacked][targetAttacked] += int16(bonus - abs(bonus) * self.getMainHistScore(sideToMove, move) div HISTORY_SCORE_CAP)


proc getEstimatedMoveScore(self: SearchManager, hashMove: Move, move: Move, ply: int): ScoredMove {.inline.} =
    ## Returns an estimated static score for the move used
    ## during move ordering
    result.move = move
    if move == hashMove:
        # The TT move always goes first
        result.data = TTMOVE_OFFSET or HashMove.int32 shl 24
        return

    if ply > 0:
        if self.isKillerMove(move, ply):
            # Killer moves come second
            result.data = KILLERS_OFFSET or KillerMove.int32 shl 24
            return

        let prevMove = self.stack[ply - 1].move
        if move == self.counters[prevMove.startSquare][prevMove.targetSquare]:
            # Counter moves come third
            result.data = COUNTER_OFFSET or CounterMove.int32 shl 24
            return

    let sideToMove = self.board.sideToMove

    # Good/bad tacticals
    if move.isTactical():
        let winning = self.parameters.see(self.board.position, move, 0)
        if move.isCapture():
            # Add capthist score
            result.data += self.getMainHistScore(sideToMove, move)
        if not winning:
            # Prioritize good exchanges (see > 0)
            if move.isCapture():   # TODO: En passant!
                # Prioritize attacking our opponent's
                # most valuable pieces
                result.data += MVV_MULTIPLIER * self.parameters.getStaticPieceScore(self.board.getPiece(move.targetSquare)).int32

            result.data += BAD_CAPTURE_OFFSET
            result.data = result.data or BadNoisy.int32 shl 24
            return
        else:
            result.data += GOOD_CAPTURE_OFFSET
            result.data = result.data or GoodNoisy.int32 shl 24
            return

    if move.isQuiet():
        result.data = QUIET_OFFSET + self.getMainHistScore(sideToMove, move).int32 + self.getContHistScore(sideToMove, self.board.getPiece(move.startSquare), move.targetSquare, ply)
        result.data = result.data or QuietMove.int32 shl 24


iterator pickMoves(self: SearchManager, hashMove: Move, ply: int, qsearch: bool = false): ScoredMove =
    ## Abstracts movegen away from search by picking moves using
    ## our move orderer
    var moves {.noinit.} = newMoveList()
    self.board.generateMoves(moves, capturesOnly=qsearch)
    var scoredMoves {.noinit.}: array[MAX_MOVES, ScoredMove]
    # Precalculate the move scores
    for i in 0..moves.high():
        scoredMoves[i] = self.getEstimatedMoveScore(hashMove, moves[i], ply)
    # Incremental selection sort: we lazily sort the move list
    # as we yield elements from it, which is on average faster than
    # sorting the entire move list with e.g. quicksort, due to the fact
    # that thanks to our pruning we don't actually explore all the moves
    for startIndex in 0..<moves.len():
        var
            bestMoveIndex = moves.len()
            bestScore = int.low()
        for i in startIndex..<moves.len():
            if scoredMoves[i].score() > bestScore:
                bestScore = scoredMoves[i].score()
                bestMoveIndex = i
        if bestMoveIndex == moves.len():
            break
        yield scoredMoves[bestMoveIndex]
        # To avoid having to keep track of the moves we've
        # already returned, we just move them to a side of
        # the list that we won't iterate anymore. This has
        # the added benefit of sorting the list of moves
        # incrementally
        let scoredMove = scoredMoves[startIndex]
        scoredMoves[startIndex] = scoredMoves[bestMoveIndex]
        scoredMoves[bestMoveIndex] = scoredMove

func isPondering*(self: SearchManager): bool {.inline.} = self.state.pondering.load()
func cancelled(self: SearchManager): bool {.inline.} = self.state.stop.load()

proc stopPondering*(self: var SearchManager) {.inline.} =
    ## Stop pondering and switch to regular search
    doAssert self.state.isMainThread.load()
    self.state.pondering.store(false)
    # Time will only be accounted for starting from
    # this point, so pondering was effectively free!
    self.limiter.enable(true)
    # No need to propagate anything to the worker threads,
    # as we're the only one doing time management


proc shouldStop*(self: var SearchManager): bool {.inline.} =
    ## Returns whether searching should
    ## stop. Only checks hard limits
    if self.cancelled() or self.expired:
        # Search has been cancelled or
        # previous shouldStop() call
        # returned true
        return true
    self.expired = self.limiter.expiredHard()
    return self.expired


proc getReduction(self: SearchManager, move: Move, depth, ply, moveNumber: int, isPV: static bool, improving, wasPV, ttCapture, cutNode: bool): int {.inline.} =
    ## Returns the amount a search depth should be reduced to
    
    const
        LMR_MOVENUMBER = (pv: 4, nonpv: 2)
        LMR_MIN_DEPTH = 3

    let moveCount = when isPV: LMR_MOVENUMBER.pv else: LMR_MOVENUMBER.nonpv
    if moveNumber > moveCount and depth >= LMR_MIN_DEPTH:
        result = LMR_TABLE[depth][moveNumber]
        when isPV:
            # Reduce PV nodes less
            dec(result, 2)

        if cutNode:
            # Expected cut nodes aren't worth searching as deep
            inc(result, 2)

        if self.stack[ply].inCheck:
            # Reduce less when we are in check
            dec(result)

        if ttCapture and move.isQuiet():
            # Hash move is a capture and current move is not: move
            # is unlikely to be better than it (due to our move
            # ordering), so we reduce more
            inc(result)
        
        if move.isQuiet():
            # Quiets are ordered later in the list, so they are generally
            # less promising
            inc(result)

        # History LMR
        if move.isQuiet() or move.isCapture():
            let stm = self.board.sideToMove
            let piece = self.board.getPiece(move.startSquare)
            var score: int = self.getMainHistScore(stm, move)
            if move.isQuiet():
                score += self.getContHistScore(stm, piece, move.targetSquare, ply)
                score = score div self.parameters.historyLmrDivisor.quiet
            else:
                score = score div self.parameters.historyLmrDivisor.noisy
            dec(result, score)

        const
            PREVIOUS_LMR_MINIMUM = 5
            PREVIOUS_LMR_DIVISOR = 5
        if ply > 0 and moveNumber >= PREVIOUS_LMR_MINIMUM:
            # The previous ply was searched with a reduced depth,
            # so we expected it to fail high quickly. Since we've
            # searched a bunch of moves and not failed high yet,
            # we might've misjudged it and it's worth to reduce
            # the current ply less
            dec(result, self.stack[ply - 1].reduction div PREVIOUS_LMR_DIVISOR)

        when not isPV:
            # If the current node previously was in the principal variation
            # and now isn't, reduce it less, as it may be good anyway
            if wasPV:
                dec(result)
        
        if improving:
            # Reduce less when improving
            dec(result)

        result = result.clamp(-1, depth - 1)


func clampEval(eval: Score): Score {.inline.} =
    ## Clamps the eval such that it is never a mate/mated
    ## score
    const matedThreshold = MAX_DEPTH - mateScore()
    result = eval.clamp(matedThreshold - 1, -matedThreshold + 1)


proc staticEval(self: SearchManager): Score =
    ## Runs the static evaluation on the current
    ## position and applies corrections to the result
    result = self.board.evaluate(self.evalState)
    # Material scaling. Yoinked from Stormphrax (see https://github.com/Ciekce/Stormphrax/compare/c4f4a8a6..6cc28cde)
    let
        knights = self.board.getBitboard(Knight)
        bishops = self.board.getBitboard(Bishop)
        pawns = self.board.getBitboard(Pawn)
        rooks = self.board.getBitboard(Rook)
        queens = self.board.getBitboard(Queen)
    
    let material = Score(self.parameters.getMaterialPieceScore(Knight) * knights.countSquares() +
                    self.parameters.getMaterialPieceScore(Bishop) * bishops.countSquares() +
                    self.parameters.getMaterialPieceScore(Pawn) * pawns.countSquares() +
                    self.parameters.getMaterialPieceScore(Rook) * rooks.countSquares() +
                    self.parameters.getMaterialPieceScore(Queen) * queens.countSquares())

    # This scales the eval linearly between base / divisor and (base + max material) / divisor
    result = result * (material + Score(self.parameters.materialScalingOffset)) div Score(self.parameters.materialScalingDivisor)
    # The contempt option is white relative, but static eval is stm relative
    let contemptValue = if self.board.sideToMove == Black: -self.contempt else: self.contempt
    # Ensure we don't return false mates
    result = (result + contemptValue).clampEval()


proc qsearch(self: var SearchManager, root: static bool, ply: int, alpha, beta: Score, isPV: static bool): Score =
    ## Negamax search with a/b pruning that is restricted to
    ## capture moves (commonly called quiescent search). The
    ## purpose of this extra search step is to mitigate the
    ## so called horizon effect that stems from the fact that,
    ## at some point, the engine will have to stop searching, possibly
    ## thinking a bad move is good because it couldn't see far enough
    ## ahead (this usually results in the engine blundering captures
    ## or sacking pieces for apparently no reason: the reason is that it
    ## did not look at the opponent's responses, because it stopped earlier.
    ## That's the horizon). To address this, we look at all possible captures
    ## in the current position and make sure that a position is evaluated as
    ## bad if only bad capture moves are possible, even if good non-capture moves
    ## exist
    if self.shouldStop() or ply >= MAX_DEPTH:
        return Score(0)
    self.statistics.selectiveDepth.store(max(self.statistics.selectiveDepth.load(), ply))
    if self.board.isDrawn(ply):
        return Score(0)
    # We don't care about the depth of cutoffs in qsearch, anything will do
    let
        query = self.transpositionTable[].get(self.board.zobristKey)
        entry = query.get(TTEntry())
        ttHit = query.isSome()
        hashMove = entry.bestMove
    var wasPV = isPV
    if not wasPV:
        wasPV = entry.flag.wasPV()
    let ttScore = Score(entry.score).decompressScore(ply)
    case entry.flag.bound():
        of NoBound:
            discard
        of Exact:
            return ttScore
        of LowerBound:
            if ttScore >= beta:
                return ttScore
        of UpperBound:
            if ttScore <= alpha:
                return ttScore
    let staticEval = if not ttHit: self.staticEval() else: query.get().staticEval
    self.stack[ply].staticEval = staticEval
    self.stack[ply].inCheck = self.board.inCheck()
    var bestScore = block:
        let flag = entry.flag.bound()
        if flag == Exact or (flag == UpperBound and ttScore < staticEval) or (flag == LowerBound and ttScore > staticEval):
            ttScore
        else:
            staticEval
    if bestScore >= beta:
        # Stand-pat evaluation
        if not bestScore.isMateScore() and not beta.isMateScore():
            bestScore = ((bestScore + beta) div 2).clampEval()
        if not ttHit:
            self.transpositionTable.store(0, staticEval, self.board.zobristKey, nullMove(), LowerBound, bestScore.int16, wasPV)
        return bestScore
    var
        alpha = max(alpha, staticEval)
        bestMove = hashMove
    for scoredMove in self.pickMoves(hashMove, ply, qsearch=true):
        let move = scoredMove.move
        let winning = block:
            # We already ran these in getEstimatedMoveScore(), so
            # we don't need to do it again
            if scoredMove.stage() == GoodNoisy:
                true
            elif scoredMove.stage() == BadNoisy:
                false
            else:
                self.parameters.see(self.board.position, move, 0)
        # Skip bad captures
        if not winning:
            continue
        let
            previous = if ply > 0: self.stack[ply - 1].move else: nullMove()
            recapture = previous != nullMove() and previous.targetSquare == move.targetSquare

        # Qsearch futility pruning: similar to FP in regular search, but we skip moves
        # that gain no material instead of just moves that don't improve alpha
        if not recapture and not self.stack[ply].inCheck and staticEval + self.parameters.qsearchFpEvalMargin <= alpha and not self.parameters.see(self.board.position, move, 1):
            continue
        let kingSq = self.board.getBitboard(King, self.board.sideToMove).toSquare()
        self.stack[ply].move = move
        self.stack[ply].piece = self.board.getPiece(move.startSquare)
        self.stack[ply].reduction = 0
        self.evalState.update(move, self.board.sideToMove, self.stack[ply].piece.kind, self.board.getPiece(move.targetSquare).kind, kingSq)
        self.board.doMove(move)
        self.statistics.nodeCount.atomicInc()
        prefetch(addr self.transpositionTable.data[getIndex(self.transpositionTable[], self.board.zobristKey)], cint(0), cint(3))
        let score = -self.qsearch(false, ply + 1, -beta, -alpha, isPV)
        self.board.unmakeMove()
        self.evalState.undo()
        if self.shouldStop():
            return Score(0)
        bestScore = max(score, bestScore)
        if score >= beta:
            # This move was too good for us, opponent will not search it
            break
        if score > alpha:
            alpha = score
            bestMove = move
            when root:
                self.statistics.bestRootScore.store(score)
                self.statistics.bestMove.store(bestMove)
    if self.shouldStop():
        return Score(0)
    if self.statistics.currentVariation.load() == 1:
        # Store the best move in the transposition table so we can find it later

        # We don't store exact scores because we only look at captures, so they are
        # very much *not* exact!
        let nodeType = if bestScore >= beta: LowerBound else: UpperBound
        var storedScore = bestScore
        # Same mate score logic of regular search
        if storedScore.isMateScore():
            storedScore += Score(storedScore.int.sgn()) * Score(ply)
        self.transpositionTable.store(0, storedScore, self.board.zobristKey, bestMove, nodeType, staticEval.int16, wasPV)
    return bestScore


func storeKillerMove(self: SearchManager, ply: int, move: Move) {.inline.} =
    ## Stores a killer move into our killers table at the given
    ## ply

    # Stolen from https://rustic-chess.org/search/ordering/killers.html

    # First killer move must not be the same as the one we're storing
    let first = self.killers[ply][0]
    if first == move:
        return
    var j = self.killers[ply].len() - 2
    while j >= 0:
        # Shift moves one spot down
        self.killers[ply][j + 1] = self.killers[ply][j];
        dec(j)
    self.killers[ply][0] = move


func clearPV(self: var SearchManager, ply: int) {.inline.} =
    ## Clears the table used to store the
    ## principal variation at the given
    ## ply
    self.pvMoves[ply][0] = nullMove()


func clearKillers(self: SearchManager, ply: int) {.inline.} =
    ## Clears the killer moves of the given
    ## ply
    for i in 0..self.killers[ply].high():
        self.killers[ply][i] = nullMove()


proc search(self: var SearchManager, depth, ply: int, alpha, beta: Score, isPV, root: static bool, cutNode: bool, excluded=nullMove()): Score {.discardable, gcsafe.} =
    ## Negamax search with various optimizations and features
    assert alpha < beta
    assert isPV or alpha + 1 == beta

    if self.shouldStop():
        return Score(0)
    if ply >= MAX_DEPTH:
        # Prevents the engine from thinking a position that
        # was extended to max ply is drawn when it isn't. This
        # is very very rare so no need to cache anything
        return self.staticEval()

    var alpha = alpha
    var beta = beta
    # Mate distance pruning: if we have a proven mate score,
    # reject lines that do not improve upon it
    when not root:
        alpha = max(alpha, matedIn(ply))
        beta = min(beta, mateIn(ply + 1))

        if alpha >= beta:
            return alpha

    when isPV:
        # Clear the PV table for this ply
        self.clearPV(ply)

    # Clearing the next ply's killers makes it so
    # that the killer table is local wrt to its
    # subtree rather than global. This makes the
    # next killer moves more relevant to our children
    # nodes, because they will only come from their
    # siblings. Idea stolen from Simbelmyne, thanks
    # @sroelants!
    if ply < self.killers[].high():
        self.clearKillers(ply + 1)

    let originalAlpha = alpha
    self.statistics.selectiveDepth.store(max(self.statistics.selectiveDepth.load(), ply))
    if self.board.isDrawn(ply):
        return Score(0)
    let sideToMove = self.board.sideToMove
    self.stack[ply].inCheck = self.board.inCheck()
    self.stack[ply].reduction = 0
    var depth = min(depth, MAX_DEPTH)
    if self.stack[ply].inCheck:
        # Check extension. We perform it now instead
        # of in the move loop because this avoids us
        # dropping into quiescent search when we are
        # in check
        depth = clamp(depth + 1, 1, MAX_DEPTH)

    if depth <= 0:
        return self.qsearch(root, ply, alpha, beta, isPV)
    let
        isSingularSearch = excluded != nullMove()
        # Probe the transposition table to see if we can cause an early cutoff
        query = self.transpositionTable.get(self.board.zobristKey)
        ttHit = query.isSome()
        entry = query.get(TTEntry())
        ttDepth = entry.depth.int
        hashMove = entry.bestMove
        ttCapture = hashMove.isCapture()
        staticEval = if not ttHit: self.staticEval() else: query.get().staticEval
        expectFailHigh {.used.} = entry.flag.bound() != UpperBound
    let ttScore = Score(entry.score).decompressScore(ply)
    var wasPV = isPV
    if not wasPV and ttHit:
        wasPV = entry.flag.wasPV()
    self.stack[ply].staticEval = staticEval
    # If the static eval from this position is greater than that from 2 plies
    # ago (our previous turn), then we are improving our position
    var improving = false
    if ply > 2 and not self.stack[ply].inCheck and not self.stack[ply - 2].inCheck:
        improving = staticEval > self.stack[ply - 2].staticEval
    if not ttHit and not isSingularSearch and not self.stack[ply].inCheck:
        # Cache static eval immediately
        self.transpositionTable.store(depth.uint8, 0, self.board.zobristKey, nullMove(), NoBound, staticEval.int16, wasPV)
    var ttPrune = false
    if ttHit and not isSingularSearch:
        # We can not trust a TT entry score for cutting off
        # this node if it comes from a shallower search than
        # the one we're currently doing, because it will not
        # have looked at all the possibilities
        if ttDepth >= depth:
            case entry.flag.bound():
                of NoBound:
                    discard
                of Exact:
                    ttPrune = true
                of LowerBound:
                    ttPrune = ttScore >= beta
                of UpperBound:
                    ttPrune = ttScore <= alpha
    if ttPrune:
        when not isPV:
            return ttScore
        else:
            # PV nodes are rare and contain a lot of valuable information,
            # so we avoid cutting them off
            depth = clamp(depth - 1, 1, MAX_DEPTH)

    when not root:
        const
            IIR_MIN_DEPTH = 3
            IIR_DEPTH_DIFFERENCE = 4

        if depth >= IIR_MIN_DEPTH and (not ttHit or ttDepth + IIR_DEPTH_DIFFERENCE < depth):
            # Internal iterative reductions: if there is no entry in the TT for
            # this node or the one we have comes from a much lower depth than the
            # current one, it's not worth it to search it at full depth, so we
            # reduce it and hope that the next search iteration yields better
            # results
            depth = clamp(depth - 1, 1, MAX_DEPTH)
    when not isPV:
        if self.stack[ply - 1].reduction > 0 and not self.stack[ply - 1].inCheck and not self.stack[ply - 1].move.isTactical() and
           (-self.stack[ply - 1].staticEval > self.stack[ply].staticEval) and self.stack[ply].staticEval < alpha:
            # If we are the child of an LMR search, and static eval suggests we might fail low (and so fail high from
            # the parent node's perspective) and we have improved the evaluation from the previous ply, we extend the
            # search depth. The heuristic is limited to non-tactical moves (to avoid eval instability) and from positions
            # that were not previously in check (as static eval is close to useless in those positions)
            depth = clamp(depth + 1, 1, MAX_DEPTH)
        if not wasPV:
            const RFP_DEPTH_LIMIT = 8

            if not self.stack[ply].inCheck and depth <= RFP_DEPTH_LIMIT:
                # Reverse futility pruning: if the static eval suggests a fail high is likely,
                # cut off the node

                let margin = (self.parameters.rfpMargins.base * depth) - self.parameters.rfpMargins.improving * improving.int

                if staticEval - margin >= beta:
                    # Instead of returning the static eval, we do something known as "fail mid"
                    # (I prefer "ultra fail retard"), which is supposed to be a better guesstimate
                    # of the positional advantage (and a better-er guesstimate than plain fail medium)
                    return (beta + (staticEval - beta) div 3).clampEval()
            
            const NMP_DEPTH_THRESHOLD = 1

            if depth > NMP_DEPTH_THRESHOLD and staticEval >= beta and ply >= self.minNmpPly and
               (not ttHit or expectFailHigh or ttScore >= beta) and self.board.canNullMove():
                # Null move pruning: it is reasonable to assume that
                # it is always better to make a move than not to do
                # so (with some exceptions noted below). To take advantage
                # of this assumption, we bend the rules a little and perform
                # a so-called "null move", basically passing our turn doing
                # nothing, and then perform a shallower search for our opponent.
                # If the shallow search fails high (i.e. produces a beta cutoff),
                # then it is useless for us to search this position any further
                # and we can just return the score outright. Since we only care about
                # whether the opponent can beat beta and not the actual value, we
                # can do a null window search and save some time, too. There are a
                # few rules that need to be followed to use NMP properly, though: we
                # must not be in check and we also must have not null-moved before
                # (that's what board.canNullMove() is checking) and the static
                # evaluation of the position needs to already be better than or
                # equal to beta
                let
                    friendlyPawns = self.board.getBitboard(Pawn, sideToMove)
                    friendlyKing = self.board.getBitboard(King, sideToMove)
                    friendlyPieces = self.board.getOccupancyFor(sideToMove)
                if not (friendlyPieces and not (friendlyKing or friendlyPawns)).isEmpty():
                    # NMP is disabled in endgame positions where only kings
                    # and (friendly) pawns are left because those are the ones
                    # where it is most likely that the null move assumption will
                    # not hold true due to zugzwang. This assumption doesn't always
                    # hold true however, and at higher depths we will do a verification
                    # search by disabling NMP for a few plies to check whether we can 
                    # actually prune the node or not, regardless of what's on the board

                    self.statistics.nodeCount.atomicInc()
                    self.board.makeNullMove()
                    # We perform a shallower search because otherwise there would be no point in
                    # doing NMP at all!
                    const
                        NMP_BASE_REDUCTION = 4
                        NMP_DEPTH_REDUCTION = 3
                        NMP_EVAL_DEPTH_MAX_REDUCTION = 3
                    var reduction = NMP_BASE_REDUCTION + depth div NMP_DEPTH_REDUCTION
                    reduction += min((staticEval - beta) div self.parameters.nmpEvalDivisor, NMP_EVAL_DEPTH_MAX_REDUCTION)
                    let score = -self.search(depth - reduction, ply + 1, -beta - 1, -beta, isPV=false, root=false, cutNode=not cutNode)
                    self.board.unmakeMove()
                    # Note to future self: having shouldStop() checks sprinkled throughout the
                    # search function makes Heimdall respect the node limit exactly. Do not change
                    # this
                    if self.shouldStop():
                        return Score(0)
                    if score >= beta:
                        const NMP_VERIFICATION_THRESHOLD = 14

                        # Note: verification search yoinked from Stormphrax
                        if depth <= NMP_VERIFICATION_THRESHOLD or self.minNmpPly > 0:
                            return score

                        # Verification search: we run a search for our side on the position
                        # before null-moving, taking care of disabling NMP for the next few
                        # plies. We only prune if this search fails high as well

                        const
                            NMP_MIN_DISABLED_PLY_MULT = 3
                            NMP_MIN_DISABLED_PLY_DIVISOR = 4
                        self.minNmpPly = ply + (depth - reduction) * NMP_MIN_DISABLED_PLY_MULT div NMP_MIN_DISABLED_PLY_DIVISOR
                        let verifiedScore = self.search(depth - reduction, ply, beta - 1, beta, isPV=false, root=false, cutNode=true)
                        # Re-enable NMP
                        self.minNmpPly = 0
                        # Verification search failed high: we're safe to prune
                        if verifiedScore >= beta:
                            return verifiedScore
    var
        bestMove = hashMove
        bestScore = lowestEval()
        # playedMoves counts how many moves we called makeMove() on, while
        # seenMoves counts how many moves were yielded by the move picker
        playedMoves = 0
        seenMoves = 0
        # Quiets that failed low
        failedQuiets {.noinit.} = newMoveList()
        # The pieces that moved for each failed
        # quiet move in the above list
        failedQuietPieces {.noinit.}: array[MAX_MOVES, Piece]
        # Captures that failed low
        failedCaptures {.noinit.} = newMoveList()
    for (move, _) in self.pickMoves(hashMove, ply):
        when root:
            if self.searchMoves.len() > 0 and move notin self.searchMoves:
                continue
        if move == excluded:
            # No counters are incremented when we encounter excluded
            # moves because we act as if they don't exist
            continue
        let
            nodesBefore {.used.} = self.statistics.nodeCount.load()
            # Ensures we don't prune moves that stave off checkmate
            isNotMated {.used.} = not bestScore.isLossScore()
            # We make move loop pruning decisions based on the depth that is
            # closer to the one the move is likely to actually be searched at
            lmrDepth {.used.} = depth - LMR_TABLE[depth][seenMoves]
        when not isPV:
            const FP_DEPTH_LIMIT = 7

            if move.isQuiet() and lmrDepth <= FP_DEPTH_LIMIT and staticEval + self.parameters.fpEvalOffset + self.parameters.fpEvalMargin * (depth + improving.int) <= alpha and isNotMated:
                # Futility pruning: If a (quiet) move cannot meaningfully improve alpha, prune it from the
                # tree. Much like RFP, this is an unsound optimization (and a riskier one at that,
                # apparently), so our depth limit and evaluation margins are very conservative
                # compared to RFP. Also, we need to make sure the best score is not a mated score, or
                # we'd risk pruning moves that evade checkmate
                inc(seenMoves)
                continue
        when not root:
            if isNotMated:
                const
                    LMP_DEPTH_OFFSET = 4
                    LMP_DEPTH_MULTIPLIER = 1

                if move.isQuiet() and playedMoves >= (LMP_DEPTH_OFFSET + LMP_DEPTH_MULTIPLIER * depth * depth) div (2 - improving.int):
                    # Late move pruning: prune moves when we've played enough of them. Since the optimization
                    # is unsound, we want to make sure we don't accidentally miss a move that staves off
                    # checkmate
                    inc(seenMoves)
                    continue
                
                const SEE_PRUNING_MAX_DEPTH = 5

                if lmrDepth <= SEE_PRUNING_MAX_DEPTH and (move.isQuiet() or move.isCapture() or move.isEnPassant()):
                    # SEE pruning: prune moves with a bad SEE score
                    let margin = -depth * (if move.isQuiet(): self.parameters.seePruningMargin.quiet else: self.parameters.seePruningMargin.capture)
                    if not self.parameters.see(self.board.position, move, margin):
                        inc(seenMoves)
                        continue
        var singular = 0
        when not root:
            const
                SE_MIN_DEPTH = 4
                SE_DEPTH_OFFSET = 4

            if not isSingularSearch and depth > SE_MIN_DEPTH and expectFailHigh and move == hashMove and ttDepth + SE_DEPTH_OFFSET >= depth:
                # Singular extensions. If there is a TT move and we expect the node to fail high, we do a null
                # window search with reduced depth (using a new beta derived from the TT score) and excluding
                # the TT move to verify whether it is the only good move: if the search fails low, then said
                # move is "singular" and it is searched with an increased depth. Note that singular extensions
                # are disabled when we are already in a singular search

                const
                    SE_DEPTH_MULTIPLIER = 1
                    SE_REDUCTION_OFFSET = 1
                    SE_REDUCTION_DIVISOR = 2
                # Derive new beta from TT score
                let
                    newBeta = Score(ttScore - SE_DEPTH_MULTIPLIER * depth)
                    newAlpha = Score(newBeta - 1)
                    newDepth = (depth - SE_REDUCTION_OFFSET) div SE_REDUCTION_DIVISOR
                    # This is basically a big comparison, asking "is there any move better than the TT move?"
                    singularScore = self.search(newDepth, ply, newAlpha, newBeta, isPV=false, root=false, cutNode=cutNode, excluded=hashMove)
                if singularScore < newBeta:
                    # Search failed low, hash move is singular: explore it deeper
                    inc(singular)
                    when not isPV:
                        # We restrict greater extensions to non-pv nodes. The consensus
                        # on this seems to be that it avoids search explosions (it can
                        # apparently be done in pv nodes with much tighter margins)

                        # Double extensions. Hash move is very singular (no close candiates)
                        # so we explore it deeper
                        if singularScore <= newAlpha - self.parameters.doubleExtMargin:
                            inc(singular)
                        # Triple extensions. Hash move is extremely singular, explore it even
                        # deeper
                        if singularScore <= newAlpha - self.parameters.tripleExtMargin:
                            inc(singular)
                # Negative extensions: hash move is not singular, but various conditions
                # suggest a cutoff is likely, so we reduce the search depth
                elif ttScore >= beta:
                    singular = -2
                elif cutNode:
                    singular = -2
                # TODO: multi-cut pruning

        self.stack[ply].move = move
        self.stack[ply].piece = self.board.getPiece(move.startSquare)
        let kingSq = self.board.getBitboard(King, self.board.sideToMove).toSquare()
        self.evalState.update(move, self.board.sideToMove, self.stack[ply].piece.kind, self.board.getPiece(move.targetSquare).kind, kingSq)
        let reduction = self.getReduction(move, depth, ply, seenMoves, isPV, improving, wasPV, ttCapture, cutNode)
        self.stack[ply].reduction = reduction
        self.board.doMove(move)
        self.statistics.nodeCount.atomicInc()
        # Find the best move for us (worst move
        # for our opponent, hence the negative sign)
        var score: Score
        # Prefetch next TT entry: 0 means read, 3 means the value has high temporal locality
        # and should be kept in all possible cache levels if possible
        prefetch(addr self.transpositionTable.data[getIndex(self.transpositionTable[], self.board.zobristKey)], cint(0), cint(3))
        # Implementation of Principal Variation Search (PVS)
        if seenMoves == 0:
            # Due to our move ordering scheme, the first move is assumed to be the best, so
            # search it always at full depth with the full search window
            score = -self.search(depth - 1 + singular, ply + 1, -beta, -alpha, isPV, false, when isPV: false else: not cutNode)
        elif reduction > 0:
            # Late Move Reductions: assume our move orderer did a good job,
            # so it is not worth it to look at all moves at the same depth equally.
            # If this move turns out to be better than we expected, we'll re-search
            # it at full depth

            # We first do a null-window reduced search to see if there's a move that beats alpha
            # (we don't care about the actual value, so we search in the range [alpha, alpha + 1]
            # to increase the number of cutoffs)
            score = -self.search(depth - 1 - reduction, ply + 1, -alpha - 1, -alpha, isPV=false, root=false, cutNode=true)
            # If the null window reduced search beats alpha, we redo the search with the same alpha
            # beta bounds without the reduction, to get a better feel for the actual score of the position.
            # If the score turns out to beat alpha (but not beta) again, we'll re-search this with a full
            # window later
            if score > alpha:
                score = -self.search(depth - 1, ply + 1, -alpha - 1, -alpha, isPV=false, root=false, cutNode=not cutNode)
        else:
            # Move wasn't reduced, just do a null window search
            score = -self.search(depth - 1, ply + 1, -alpha - 1, -alpha, isPV=false, root=false, cutNode=not cutNode)
        if seenMoves > 0 and score > alpha and score < beta:
            # The position beat alpha (and not beta, which would mean it was too good for us and
            # our opponent wouldn't let us play it) in the null window search, search it
            # again with the full depth and full window. Note to future self: alpha and beta
            # are integers, so in a non-pv node it's never possible that this condition is triggered
            # since there's no value between alpha and beta (which is alpha + 1)
            score = -self.search(depth - 1, ply + 1, -beta, -alpha, isPV, root=false, cutNode=false)
        if self.shouldStop():
            self.evalState.undo()
            self.board.unmakeMove()
            return Score(0)
        inc(playedMoves)
        inc(seenMoves)
        when root:
            # Record how many nodes were spent on each root move
            let nodesAfter = self.statistics.nodeCount.load()
            self.statistics.spentNodes[move.startSquare][move.targetSquare].atomicInc(nodesAfter - nodesBefore)
        self.board.unmakeMove()
        self.evalState.undo()
        bestScore = max(score, bestScore)
        if score >= beta:
            # This move was too good for us, opponent will not search it
            when not root:
                if not (move.isCapture() or move.isEnPassant()):
                    # Countermove heuristic: we assume that most moves have a natural
                    # response irrespective of the actual position and store them in a
                    # table indexed by the from/to squares of the previous move
                    let prevMove = self.stack[ply - 1].move
                    self.counters[prevMove.startSquare][prevMove.targetSquare] = move
            
            let histDepth = depth + (bestScore - beta > self.parameters.historyDepthEvalThreshold).int
            if move.isQuiet():
                # If the best move we found is a tactical move, we don't want to punish quiets
                # because they still might be good (just not as good wrt the best move)
                if not bestMove.isTactical():
                    # Give a bonus to the quiet move that failed high so that we find it faster later
                    self.updateHistories(sideToMove, move, self.stack[ply].piece, histDepth, ply, true)
                    # Punish quiet moves coming before this one such that they are placed later in the
                    # list in subsequent searches and we manage to cut off faster
                    for i, quiet in failedQuiets:
                        self.updateHistories(sideToMove, quiet, failedQuietPieces[i], histDepth, ply, false)
                # Killer move heuristic: store quiets that caused a beta cutoff according to the distance from
                # root that they occurred at, as they might be good refutations for future moves from the opponent.
                self.storeKillerMove(ply, move)

            if move.isCapture():
                # It doesn't make a whole lot of sense to give a bonus to a capture
                # if the best move is a quiet move, does it? (This is also why we
                # don't give a bonus to quiets if the best move is a tactical move)
                if bestMove.isCapture():
                    self.updateHistories(sideToMove, move, nullPiece(), histDepth, ply, true)

                # We always apply the malus to captures regardless of what the best
                # move is because if a quiet manages to beat all previously seen captures
                # we still want to punish them, otherwise we'd think they're better than
                # they actually are!
                for capture in failedCaptures:
                    self.updateHistories(sideToMove, capture, nullPiece(), histDepth, ply, false)
            break
        if score > alpha:
            alpha = score
            bestMove = move
            when root:
                self.statistics.bestRootScore.store(score)
                self.statistics.bestMove.store(bestMove)
            when isPV:
                # This loop is why pvMoves has one extra move.
                # We can just do ply + 1 and i + 1 without ever
                # fearing about buffer overflows
                for i, pvMove in self.pvMoves[ply + 1]:
                    if pvMove == nullMove():
                        # Terminate the PV so moves from previous
                        # searches don't show up when printing it
                        self.pvMoves[ply][i + 1] = nullMove()
                        break
                    self.pvMoves[ply][i + 1] = pvMove
                self.pvMoves[ply][0] = move
        else:
            if move.isQuiet():
                failedQuiets.add(move)
                failedQuietPieces[failedQuiets.high()] = self.stack[ply].piece
            elif move.isCapture():
                failedCaptures.add(move)
    if seenMoves == 0:
        # No moves were yielded by the move picker: no legal moves
        # available!
        if self.stack[ply].inCheck:
            # Checkmate!
            return matedIn(ply)
        # Stalemate
        return if not isSingularSearch: Score(0) else: alpha
    # Don't store in the TT during a singular search. We also don't overwrite
    # the entry in the TT for the root node to avoid poisoning the original
    # score
    if not isSingularSearch and (not root or self.statistics.currentVariation.load() == 1) and not self.expired and not self.cancelled():
        # Store the best move in the transposition table so we can find it later
        let nodeType = if bestScore >= beta: LowerBound elif bestScore <= originalAlpha: UpperBound else: Exact
        self.transpositionTable.store(depth.uint8, bestScore.compressScore(ply), self.board.zobristKey, bestMove, nodeType, staticEval.int16, wasPV)

    return bestScore


proc startClock*(self: var SearchManager) =
    ## Starts the manager's internal clock if
    ## it wasn't already started. If we're not
    ## the main thread, this is a no-op
    if not self.state.isMainThread.load() or self.clockStarted:
        return
    self.state.searchStart.store(getMonoTime())
    self.clockStarted = true


proc aspirationSearch(self: var SearchManager, depth: int, score: Score): Score {.inline.} =
    var
        delta = Score(self.parameters.aspWindowInitialSize)
        alpha = max(lowestEval(), score - delta)
        beta = min(highestEval(), score + delta)
        reduction = 0
        score = score
    while true:
        score = self.search(depth - reduction, 0, alpha, beta, true, true, false)
        if self.shouldStop() or self.limiter.expiredSoft():
            break
        # Score is outside window bounds, widen the one that
        # we got past to get a better result
        if score <= alpha:
            alpha = max(lowestEval(), score - delta)
            # Grow the window downward as well when we fail
            # low (cuts off faster)
            beta = (alpha + beta) div 2
            # Reset the reduction whenever we fail low to ensure
            # we don't miss good stuff that seems bad at first
            reduction = 0
        elif score >= beta:
            beta = min(highestEval(), score + delta)
            # Whenever we fail high, reduce the search depth as we
            # expect the score to be good for our opponent anyway
            reduction += 1
        else:
            # Value was within the alpha-beta bounds, we're done
            break
        # Try again with larger window
        delta += delta
        if delta >= Score(self.parameters.aspWindowMaxSize):
            # Window got too wide, give up and search with the full range
            # of alpha-beta values
            delta = highestEval()
    return score


proc search*(self: var SearchManager, searchMoves: seq[Move] = @[], silent=false, ponder=false, minimal=false, variations=1): seq[array[MAX_DEPTH + 1, Move]] =
    ## Begins a search, limiting search time according the
    ## the manager's limiter configuration. If ponder equals
    ## true, the search will ignore all limits until the
    ## stopPondering() procedure is called, after which search
    ## will be limited as if they were imposed from the moment
    ## after the call. If silent equals true, search logs will
    ## not be printed. If variations > 1, the specified number
    ## of alternative variations (up to MAX_MOVES) is searched (note
    ## that time and node limits are shared across all of them), and
    ## they are all returned. The number of alternative variations is
    ## always clamped to the number of legal moves available on the board
    ## or (when provided), the specified number of root moves to search,
    ## whichever is smallest. If searchMoves is nonempty, only the specified
    ## set of root moves is considered (the moves in the list are assumed to be
    ## legal). If minimal is true and logs are not silenced, only the final log
    ## message is printed. If getWorkerCount() is > 0, the search is performed
    ## by the calling thread plus that many additional threads in parallel

    if ponder:
        self.limiter.disable()
    else:
        # Just in case it was disabled earlier
        self.limiter.enable()
    if silent:
        self.logger.disable()
    else:
        self.logger.enable()
    # Clean up the search state and statistics
    self.startClock()
    self.state.pondering.store(ponder)
    self.searchMoves = searchMoves
    self.statistics.nodeCount.store(0)
    self.statistics.highestDepth.store(0)
    self.statistics.selectiveDepth.store(0)
    self.statistics.bestRootScore.store(0)
    self.statistics.bestMove.store(nullMove())
    self.statistics.currentVariation.store(0)
    self.state.stop.store(false)
    self.state.searching.store(true)
    self.expired = false

    for i in Square(0)..Square(63):
        for j in Square(0)..Square(63):
            self.statistics.spentNodes[i][j].store(0)

    var score = Score(0)
    var bestMoves: seq[Move] = @[]
    var legalMoves {.noinit.} = newMoveList()
    var variations = min(MAX_MOVES, variations)

    if variations > 1:
        self.board.generateMoves(legalMoves)
        if searchMoves.len() > 0:
            variations = min(variations, searchMoves.len())
    
    var lastInfoLine = false

    result = newSeq[array[MAX_DEPTH + 1, Move]](variations)
    for i in 0..<variations:
        for j in 0..MAX_DEPTH:
            self.previousLines[i][j] = nullMove()
    for i in 0..<MAX_MOVES:
        self.previousScores[i] = Score(0)

    # Start worker threads
    self.workerPool.startSearch(searchMoves, variations)

    block iterativeDeepening:
        # Iterative deepening loop
        for depth in 1..MAX_DEPTH:
            if self.limiter.expiredSoft():
                break iterativeDeepening
            self.limiter.scale(self.parameters)
            for i in 1..variations:
                self.statistics.selectiveDepth.store(0)
                self.statistics.currentVariation.store(i)
                
                const ASPIRATION_WINDOW_DEPTH_THRESHOLD = 5
    
                if depth < ASPIRATION_WINDOW_DEPTH_THRESHOLD:
                    score = self.search(depth, 0, lowestEval(), highestEval(), true, true, false)
                else:
                    # Aspiration windows: start subsequent searches with tighter
                    # alpha-beta bounds and widen them as needed (i.e. when the score
                    # goes beyond the window) to increase the number of cutoffs
                    score = self.aspirationSearch(depth, score)
                if self.shouldStop() or self.pvMoves[0][0] == nullMove():
                    # Search has likely been interrupted mid-tree (or
                    # before it could search enough moves): cannot
                    # trust partial results
                    lastInfoLine = self.cancelled() or self.limiter.hardTimeLimitReached() or self.pvMoves[0][0] == nullMove()
                    break iterativeDeepening
                bestMoves.add(self.pvMoves[0][0])
                self.previousLines[i - 1] = self.pvMoves[0]
                result[i - 1] = self.pvMoves[0]
                self.previousScores[i - 1] = score
                self.statistics.highestDepth.store(depth)
                if not silent and not minimal:
                    self.logger.log(self.pvMoves[0], i)
                if variations > 1:
                    self.searchMoves = searchMoves
                    for move in legalMoves:
                        if searchMoves.len() > 0 and move notin searchMoves:
                            # If the user told us to only search a specific set
                            # of moves, don't override that
                            continue
                        if move in bestMoves:
                            # Don't search the current best move(s) in the next search
                            continue
                        self.searchMoves.add(move)
            bestMoves.setLen(0)

    var stats = self.statistics
    var finalScore = self.previousScores[0]
    if self.state.isMainThread.load():
        # The main thread is the only one doing time management,
        # so we need to explicitly stop all other workers
        self.stop()

        var bestSearcher = addr self

        # Wait for all workers to stop searching and answer to our pings
        for i, worker in self.workerPool.workers:
            worker.ping()
            # Pick the best result across all of our threads. Logic yoinked from
            # Ethereal
            let
                bestDepth = bestSearcher.statistics.highestDepth.load()
                bestScore = bestSearcher.statistics.bestRootScore.load()
                currentDepth = worker.manager.statistics.highestDepth.load()
                currentScore = worker.manager.statistics.bestRootScore.load()

            # Thread has the same depth but better score than our best
            # so far or a shorter mate (or longer mated) line than what
            # we currently have
            if (bestDepth == currentDepth and currentScore > bestScore) or (currentScore.isMateScore() and currentScore > bestScore):  
                bestSearcher = addr worker.manager

            # Thread has a higher search depth than our best one and does
            # not replace a (closer) mate score
            if currentDepth > bestDepth and (currentScore > bestScore or not bestScore.isMateScore()):
                bestSearcher = addr worker.manager

        if not bestSearcher.state.isMainThread.load():
            # We picked a different line from the one of the main thread:
            # print the last info line such that it is obvious from the
            # outside
            lastInfoLine = true
            # TODO: Look into whether this fucks up the reporting.
            # Incomplete worker searches could cause issues. Only
            # visual things, but still
            stats = bestSearcher.statistics
            finalScore = bestSearcher.statistics.bestRootScore.load()
            for i in 0..<result.len():
                result[i] = bestSearcher.previousLines[i]

    if not silent and (lastInfoLine or minimal):
        # Log final info message
        self.logger.log(result[0], 1, some(finalScore), some(stats))

    # Reset atomics
    self.state.searching.store(false)
    self.state.pondering.store(false)
    self.clockStarted = false

