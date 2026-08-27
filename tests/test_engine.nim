## The decision loop: ONE parallel batch of eight per turn, one bounded retry,
## the scripted fallback, the budget guard, and the per-turn wall clock.

import std/[json, monotimes, os, times]
import lib/helpers
import grf_football/server

type Recorder = ref object
  calls: seq[int]          ## entries per batch call
  timeouts: seq[int]
  seats: seq[seq[int]]

proc replyingBatch(rec: Recorder, body: string): BatchFn =
  result = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    rec.calls.add(calls.len)
    rec.timeouts.add(timeoutSeconds)
    var seats: seq[int]
    for call in calls:
      seats.add(call.seat)
      result.add BatchReply(seat: call.seat, ok: true, text: body)
    rec.seats.add(seats)

proc failingBatch(rec: Recorder, error: string): BatchFn =
  result = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    rec.calls.add(calls.len)
    rec.timeouts.add(timeoutSeconds)
    var seats: seq[int]
    for call in calls:
      seats.add(call.seat)
      result.add BatchReply(seat: call.seat, ok: false, error: error)
    rec.seats.add(seats)

proc llmEngine(batch: BatchFn): TurnEngine =
  result = newTurnEngine(nil, batch)
  for seat in 0 ..< SeatCount:
    result.policies[seat] = SeatPolicy(kind: pkLlm, prompt: "play well",
      label: "test", connected: true)

const GoodReply = """{"note":"press and support",
  "cogs":[{"id":"RED-9","intent":"press","target":[4,2],
           "on_ball":"pass_short","sprint":"auto","tackle":"auto",
           "say":"on him"}]}"""

proc oneBatchOfEightPerTurn() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let engine = llmEngine(replyingBatch(rec, GoodReply))
  engine.turn(sim, 0, 0)
  doAssert rec.calls.len == 1,
    "all eight seats go out as ONE batch, got " & $rec.calls.len & " calls"
  doAssert rec.calls[0] == SeatCount,
    "the single batch carries all eight seats, got " & $rec.calls[0]
  var seen: array[SeatCount, bool]
  for seat in rec.seats[0]:
    seen[seat] = true
  for seat in 0 ..< SeatCount:
    doAssert seen[seat], "seat " & $seat & " was not in the batch"
    doAssert sim.hasDirective[seat]
    doAssert sim.activeDirective[seat].source == dsLlm
    doAssert sim.seatStats[seat].llmTurns == 1
  report "all eight seats' calls go out as ONE parallel batch per turn"

proc timeoutRetriesOnceThenFallsBack() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let engine = llmEngine(failingBatch(rec, "Operation timed out after 6000 ms"))
  engine.turn(sim, 1, 0)
  doAssert rec.calls.len == 2,
    "a failure retries EXACTLY once, got " & $rec.calls.len & " attempts"
  doAssert rec.calls[1] == SeatCount, "the retry is one batch too"
  for seat in 0 ..< SeatCount:
    doAssert sim.activeDirective[seat].source == dsFallback,
      "two failures fall back to the scripted layer"
    doAssert sim.seatStats[seat].fallbackTurns == 1
  var timeouts = 0
  for record in engine.records:
    let node = parseJson(record)
    if node{"k"}.getStr == "fallback":
      doAssert node{"cause"}.getStr == "timeout",
        "a curl deadline reads as `timeout`, got " & node{"cause"}.getStr
      inc timeouts
  doAssert timeouts == 2 * SeatCount,
    "one fallback record per failed attempt per seat, got " & $timeouts
  report "a timeout retries exactly once, then falls back to zonal"

proc parseFailureIsRepairedOrRetried() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let engine = llmEngine(replyingBatch(rec, "I am not going to answer."))
  engine.turn(sim, 2, 0)
  doAssert rec.calls.len == 2, "unparseable text retries once"
  for seat in 0 ..< SeatCount:
    doAssert sim.activeDirective[seat].source == dsFallback
  var causes: seq[string]
  for record in engine.records:
    let node = parseJson(record)
    if node{"k"}.getStr == "fallback":
      causes.add(node{"cause"}.getStr)
  doAssert "parse_error" in causes, "the cause names the parse failure"
  report "an unparseable reply retries once and then plays zonal"

proc noCredentialsNeverBlocks() =
  var sim = playing(testConfig())
  let engine = newTurnEngine(nil, nil)     ## no client, no transport
  for seat in 0 ..< SeatCount:
    engine.policies[seat] = SeatPolicy(kind: pkLlm, prompt: "x",
      label: "x", connected: true)
  let started = getMonoTime()
  engine.turn(sim, 0, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds
  doAssert elapsed < 2000,
    "with no credentials the turn must cost nothing, took " & $elapsed & " ms"
  var sawNoCredentials = false
  for record in engine.records:
    let node = parseJson(record)
    if node{"k"}.getStr == "fallback" and
        node{"cause"}.getStr == "no_credentials":
      sawNoCredentials = true
  doAssert sawNoCredentials, "the record names `no_credentials`"
  for seat in 0 ..< SeatCount:
    doAssert sim.hasDirective[seat], "no seat is left unactuated"
  report "a seat with no credentials records no_credentials and never blocks"

proc budgetGuardFires() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let engine = llmEngine(replyingBatch(rec, GoodReply))
  # Two more turns no longer fit inside the wall-clock budget.
  engine.turn(sim, 20, sim.config.wallClockBudgetSeconds - 5)
  doAssert engine.llmOff, "the budget guard switches the LLM off"
  doAssert engine.guardTurn == 20
  doAssert rec.calls.len == 0, "no batch is issued once the guard has fired"
  var sawGuard = false
  for record in engine.records:
    let node = parseJson(record)
    if node{"k"}.getStr == "budget_guard":
      sawGuard = true
      doAssert node{"turn"}.getInt == 20
  doAssert sawGuard, "a budget_guard record names the turn it fired"
  for seat in 0 ..< SeatCount:
    doAssert sim.activeDirective[seat].source == dsFallback
  report "the budget guard fires and finishes the match on the scripted layer"

proc turnStaysInsideItsBudget() =
  var sim = playing(testConfig())
  let rec = Recorder()
  let engine = llmEngine(replyingBatch(rec, GoodReply))
  let started = getMonoTime()
  for turn in 0 ..< 4:
    engine.turn(sim, turn, 0)
  let elapsed = (getMonoTime() - started).inMilliseconds
  doAssert elapsed < int64(4 * sim.config.turnBudgetMs),
    "four turns must stay inside four turn budgets, took " & $elapsed & " ms"
  for t in rec.timeouts:
    doAssert t >= 1, "curly's whole-second floor is respected"
    doAssert t <= (sim.config.attempt1Ms div 1000),
      "an attempt is never given more than its allowance"
  report "a turn's wall clock never exceeds turnBudgetMs"

proc failureDeclarationShape() =
  ## The lobby no-show declaration the platform runner polls for.
  let path = tempPath("player-failure.json")
  putEnv("COGAME_PLAYER_FAILURE_URI", "file://" & path)
  declarePlayerFailure(3, "slot 3 never joined")
  doAssert fileExists(path), "the declaration is written"
  let node = parseJson(readFile(path))
  doAssert node{"failed_policy_index"}.getInt == 3
  doAssert node{"message"}.getStr.len > 0
  removeFile(path)
  delEnv("COGAME_PLAYER_FAILURE_URI")
  report "declarePlayerFailure writes the shape the runner polls for"

when isMainModule:
  echo "test_engine"
  oneBatchOfEightPerTurn()
  timeoutRetriesOnceThenFallsBack()
  parseFailureIsRepairedOrRetried()
  noCredentialsNeverBlocks()
  budgetGuardFires()
  turnStaysInsideItsBudget()
  failureDeclarationShape()
  echo "test_engine ok"
