## The turn engine: one decision every 240 ticks, ALL EIGHT SEATS issued as ONE
## parallel batch, two bounded attempts, then the scripted fallback.
##
## Timing (docs/RULES.md §Budget):
##   attempt 1 batch deadline   6.0 s   (config attempt1Ms)
##   retry batch deadline       3.0 s   (config retryMs)
##   outer monotonic turn cap  10.0 s   (config turnBudgetMs)
##   rate floor between batch STARTS 18.0 s (config turnSpacingMs)
## curly's transport timeout is whole seconds and a batch in flight cannot be
## interrupted, so the per-attempt allowance is floored to whole seconds before
## it is handed over: 6 s + 3 s = 9 s realised worst case, inside the 10 s cap.
## The rate floor dominates: 24 turns x 18 s = 432 s, which pins the episode at
## 8 x 60/18 = 26.7 requests/minute — inside the hosted sidecar's 30/min
## episode cap. The certification fixture sets `turnSpacingMs` to 0, so offline
## runs pay nothing.
##
## Seats are NEVER queried sequentially: football is a simultaneous-decision
## game. The transport is injected as a `BatchFn` so tests/test_engine.nim can
## hand in a fake that asserts ONE `makeRequests` call carrying eight entries.

import
  std/[json, monotimes, os, strutils, times],
  curly,
  sim, directives, baselines, builtin_ai, llm

const SystemPrompt* = """You are one footballer in an 11-a-side match, played in a top-down 2D physics world.
You control ONE shirt. Your other ten teammates are run by the engine's built-in AI:
they hold a 4-3-3 shape, tackle when the ball is at their feet, pass to the nearest
better-placed teammate, and never dribble far. Three other shirts on your team are
controlled by other policies you cannot talk to.
Every 10 seconds of match time you issue ONE order for your shirt. A deterministic
controller executes it for the next 10 seconds: it steers your cog, sprints, tackles
and plays the ball for you according to your order.
The pitch is 84 by 54 metres. You attack toward the goal named in "attacking_goal".
The ball goes OUT: throw-ins, corners and goal kicks are real. There is no offside.
A slide tackle that misses the ball and hits the opponent is a foul: you lose the
ball and lie grounded for two seconds. Sprinting drains stamina; low stamina makes
you slow for the rest of the match.
Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
Schema:
{"note":"<=160 chars",
 "cogs":[{"id":"<your shirt id>",
          "role":"striker|winger|playmaker|anchor",
          "intent":"press|hold_shape|make_run|support|drop_deep|carry|switch_play|shadow",
          "target":[x,y],
          "on_ball":"shoot|pass_short|pass_long|pass_high|dribble|hold",
          "pass_to":"<teammate shirt id or null>",
          "sprint":"auto|always|never",
          "tackle":"auto|never",
          "say":"<=48 chars"}]}
Exactly one entry, for the shirt you control.
Intents: press = close down whoever has the ball; hold_shape = hold your target and
face the ball; make_run = run into space ahead of the ball on your side; support =
offer a short passing option beside the ball; drop_deep = come back toward your own
goal to receive; carry = go get the ball and run with it; switch_play = move to the
far side of the pitch; shadow = mark the nearest opponent.
target is metres: x in [-42,42], y in [-27,27]. It is used directly by hold_shape and
as a bias by everything else.
on_ball is what you do when the ball is at YOUR feet; the controller ignores an
illegal choice (a shot from 60 metres, a pass to nobody) and plays the safe option."""

type
  BatchCall* = object
    seat*: int
    system*, user*: string

  BatchReply* = object
    seat*: int
    ok*: bool
    text*: string
    error*: string

  BatchFn* = proc (
    calls: seq[BatchCall],
    timeoutSeconds: int
  ): seq[BatchReply] {.closure, gcsafe.}

  SeatPolicy* = object
    kind*: PolicyKind
    prompt*: string            ## never recorded, never echoed.
    baseline*: string
    label*: string
    connected*: bool

  TurnEngine* = ref object
    client*: LlmClient
    batch*: BatchFn
    policies*: array[SeatCount, SeatPolicy]
    previous*: array[SeatCount, Directive]
    hasPrevious*: array[SeatCount, bool]
    lastCogStats*: array[CogCount, CogStats]
    lastTeamStats*: array[Team, TeamStats]
    lastGoals*: seq[JsonNode]
    llmOff*: bool
    guardTurn*: int
    lastBatchStart*: MonoTime
    hasBatched*: bool
    records*: seq[string]      ## the replay chat records this turn produced.

# --------------------------------------------------------------------------
# The per-seat view
# --------------------------------------------------------------------------

proc cogViewJson(sim: SimServer, index: int, own: bool): JsonNode =
  result = %*{
    "id": cogId(index),
    "pos": [round1(viewX(sim.cogs[index].x)), round1(viewY(sim.cogs[index].y))],
    "dist_to_ball": round1(float(sim.distToBall(index)) / 1_000_000.0)
  }
  if own:
    result["has_ball"] = %(sim.ball.controller == int32(index))

proc teamViewJson(sim: SimServer, team: Team, own: bool): JsonNode =
  result = newJArray()
  for j in 0 ..< CogsPerTeam:
    let i = firstCogOf(team) + j
    var entry = cogViewJson(sim, i, false)
    if own:
      entry["role"] =
        %(if sim.cogs[i].seat >= 0: roleText(SeatRole[int(sim.cogs[i].seat)])
          elif isKeeper(i): "keeper"
          else: "builtin")
      entry["driver"] = %(if sim.cogs[i].seat >= 0: "seat" else: "builtin")
    else:
      entry["has_ball"] = %(sim.ball.controller == int32(i))
    result.add(entry)

proc seatViewJson*(
  engine: TurnEngine,
  sim: SimServer,
  seat: int,
  turn: int
): JsonNode =
  ## Everything the seat sees, in view coordinates (metres, centred), rounded
  ## to one decimal. Never contains a real player name, the seed, another
  ## seat's directive, or any future tick.
  let
    index = cogOfSeat(seat)
    team = teamOfSeat(seat)
    foe = other(team)
    played = float(sim.gameTicksElapsed()) / float(TargetFps)
    total = float(sim.config.maxTicks) / float(TargetFps)
    me = sim.cogStats[index]
    prevMe = engine.lastCogStats[index]
    possMe = sim.teamStats[team].possessionTicks -
      engine.lastTeamStats[team].possessionTicks
    possThem = sim.teamStats[foe].possessionTicks -
      engine.lastTeamStats[foe].possessionTicks
    possTotal = max(1, int(possMe + possThem))
    nearest = sim.nearestOpponent(index)
    penalty =
      if team == Red: "x <= -26, |y| <= 20" else: "x >= 26, |y| <= 20"
  var goalsJson = newJArray()
  for entry in engine.lastGoals:
    var copied = copy(entry)
    copied["for"] =
      %(if entry{"team"}.getInt() == ord(team): "you" else: "them")
    copied.delete("team")
    goalsJson.add(copied)
  var restart = newJNull()
  if sim.restartTicks > 0:
    restart = %*{
      "kind": restartText(sim.restartKind),
      "team": (if sim.restartTeam >= 0:
        %teamPrefix(Team(sim.restartTeam and 1)) else: newJNull()),
      "taker": (if sim.restartTaker >= 0:
        %cogId(int(sim.restartTaker)) else: newJNull()),
      "ticks_left": int(sim.restartTicks)
    }
  result = %*{
    "turn": turn,
    "of": sim.turnCount(),
    "half": int(sim.half),
    "clock": {"played_s": round1(played), "left_s": round1(total - played)},
    "score": {"you": sim.goals(team), "them": sim.goals(foe)},
    "you": {
      "id": cogId(index),
      "role": roleText(SeatRole[seat]),
      "team": teamPrefix(team),
      "attacking_goal": [round1(viewX(targetGoalX(team))), 0.0],
      "defending_goal": [round1(viewX(ownGoalX(team))), 0.0]
    },
    "pitch": {
      "x_min": -ViewHalfW, "x_max": ViewHalfW,
      "y_min": -ViewHalfH, "y_max": ViewHalfH,
      "goal_half_width": GoalHalfWidth,
      "your_penalty_area": penalty,
      "offside": false
    },
    "phase": (if sim.restartTicks > 0: restartText(sim.restartKind)
              else: "playing"),
    "restart": restart,
    "ball": {
      "pos": [round1(viewX(sim.ball.x)), round1(viewY(sim.ball.y))],
      "vel": [round1(metresPerSecond(sim.ball.vx)),
              round1(metresPerSecond(sim.ball.vy))],
      "speed": round1(metresPerSecond(speedOf(sim.ball.vx, sim.ball.vy))),
      "height": round1(float(sim.ball.z) / 1_000_000.0),
      "controller": (if sim.ball.controller >= 0:
        %cogId(int(sim.ball.controller)) else: newJNull()),
      "in_your_half": sim.ballInOwnHalf(team)
    },
    "your_cog": {
      "id": cogId(index),
      "pos": [round1(viewX(sim.cogs[index].x)),
              round1(viewY(sim.cogs[index].y))],
      "vel": [round1(metresPerSecond(sim.cogs[index].vx)),
              round1(metresPerSecond(sim.cogs[index].vy))],
      "speed": round1(metresPerSecond(
        speedOf(sim.cogs[index].vx, sim.cogs[index].vy))),
      "stamina": int(sim.cogs[index].stamina),
      "sprinting": sim.cogs[index].sprinting,
      "dribbling": sim.cogs[index].dribbling,
      "grounded": sim.cogs[index].groundedTicks > 0,
      "dist_to_ball": round1(float(sim.distToBall(index)) / 1_000_000.0),
      "has_ball": sim.ball.controller == int32(index),
      "nearest_opponent": (
        if nearest >= 0:
          %*{"id": cogId(nearest),
             "dist": round1(float(distI(
               sim.cogs[nearest].x - sim.cogs[index].x,
               sim.cogs[nearest].y - sim.cogs[index].y)) / 1_000_000.0)}
        else: newJNull())
    },
    "your_team": teamViewJson(sim, team, true),
    "their_team": teamViewJson(sim, foe, false),
    "last_turn": {
      "your_passes": int(me.passes - prevMe.passes),
      "your_passes_completed": int(me.passesCompleted -
        prevMe.passesCompleted),
      "your_shots": int(me.shots - prevMe.shots),
      "your_tackles": int(me.tackles - prevMe.tackles),
      "team_possession_pct": int(possMe) * 100 div possTotal,
      "goals": goalsJson
    },
    "your_last_directive": (
      if engine.hasPrevious[seat]: %engine.previous[seat].note
      else: newJNull())
  }

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userMessage*(
  engine: TurnEngine,
  sim: SimServer,
  seat: int,
  turn: int
): string =
  operatorBlock(engine.policies[seat].prompt) &
    $engine.seatViewJson(sim, seat, turn)

# --------------------------------------------------------------------------
# The transport
# --------------------------------------------------------------------------

proc curlyBatch*(client: LlmClient): BatchFn =
  ## The production transport: ONE `curly.makeRequests` call per attempt, so
  ## all eight seats are in flight together. curly's timeout is whole seconds
  ## and nothing interrupts a batch already in flight, so the caller rounds the
  ## allowance DOWN (floor, with a one-second minimum) before handing it over.
  result = proc (calls: seq[BatchCall], timeoutSeconds: int): seq[BatchReply]
      {.closure, gcsafe.} =
    result = @[]
    if calls.len == 0:
      return
    var batch: RequestBatch
    for call in calls:
      let request = client.requestFor(call.system, call.user)
      batch.post(request.url, request.headers, request.body, $call.seat)
    let responses = client.curl.makeRequests(batch, max(1, timeoutSeconds))
    for i, call in calls:
      var reply = BatchReply(seat: call.seat)
      if i >= responses.len:
        reply.error = "no response"
        result.add(reply)
        continue
      let (response, error) = responses[i]
      if error.len > 0:
        reply.error = error
      else:
        try:
          reply.text = client.completionText(response.code, response.body)
          reply.ok = true
        except CatchableError as failure:
          reply.error = failure.msg
      result.add(reply)

# --------------------------------------------------------------------------
# The turn
# --------------------------------------------------------------------------

proc newTurnEngine*(client: LlmClient, batch: BatchFn): TurnEngine =
  result = TurnEngine(client: client, batch: batch, guardTurn: -1)
  for seat in 0 ..< SeatCount:
    result.previous[seat] = emptyDirective(seat)

proc addRecord(engine: TurnEngine, node: JsonNode) =
  engine.records.add(capRecord($node))

proc noteGoal*(engine: TurnEngine, tick: int, cog: int, team: Team) =
  ## Called by the server when a goal lands, so the next turn's view can report
  ## it. Bounded to the last handful.
  engine.lastGoals.add(%*{
    "tick": tick,
    "by": (if cog >= 0: cogId(cog) else: "own goal"),
    "team": ord(team)
  })
  while engine.lastGoals.len > 4:
    engine.lastGoals.delete(0)

proc fallbackFor(
  engine: TurnEngine,
  sim: SimServer,
  seat: int,
  turn: int
): Directive =
  ## The `zonal` order is the fallback for every failure mode.
  result = sim.zonalDirective(seat, turn)
  result.source = dsFallback

proc spacingSeconds(config: GameConfig): int {.inline.} =
  ## The rate floor in whole seconds; when it is off (the cert fixture) the
  ## turn budget stands in, so the guard still means something.
  if config.turnSpacingMs > 0: (config.turnSpacingMs + 999) div 1000
  else: (config.turnBudgetMs + 999) div 1000

proc turn*(
  engine: TurnEngine,
  sim: var SimServer,
  turnIndex: int,
  elapsedSeconds: int
) =
  ## Runs one decision turn: at most one parallel batch plus at most one
  ## parallel retry, all inside a monotonic `turnBudgetMs` bound, then installs
  ## all eight seats' directives and writes the records.
  engine.records.setLen(0)
  let
    budget = sim.config.wallClockBudgetSeconds
    perTurn = spacingSeconds(sim.config)

  # Budget guard: switch the LLM off for the rest of the match rather than let
  # the episode end `deadline`. Microseconds per turn from here on.
  if not engine.llmOff and elapsedSeconds + 2 * perTurn > budget:
    engine.llmOff = true
    engine.guardTurn = turnIndex
    engine.addRecord(%*{
      "k": "budget_guard",
      "turn": turnIndex,
      "remaining_s": budget - elapsedSeconds
    })
    echo "grf-football: budget guard at turn ", turnIndex,
      "; falling back to the scripted layer for the rest of the match"

  var
    resolved: array[SeatCount, Directive]
    settled: array[SeatCount, bool]
    calls: seq[BatchCall]
  for seat in 0 ..< SeatCount:
    let policy = engine.policies[seat]
    if policy.kind == pkScripted:
      resolved[seat] = sim.baselineDirective(seat, policy.baseline, turnIndex)
      settled[seat] = true
    elif engine.llmOff or engine.batch.isNil or
        (not engine.client.isNil and engine.client.disabled):
      # A nil CLIENT with a live batch is the test seam (tests/test_engine.nim
      # injects a fake transport); a nil BATCH is the real no-credentials path.
      resolved[seat] = engine.fallbackFor(sim, seat, turnIndex)
      settled[seat] = true
      let rejected =
        not engine.client.isNil and engine.client.transport != ltNone
      let cause =
        if engine.llmOff: "budget_guard"
        elif rejected: "transport_error"
        else: "no_credentials"
      let detail =
        if rejected: "credentials rejected; the client is disabled for the " &
          "rest of the episode"
        else: ""
      engine.addRecord(%*{
        "k": "fallback", "turn": turnIndex, "seat": seat,
        "attempt": 1, "cause": cause,
        "detail": clipRunes(detail, MaxDetailRunes)
      })
    else:
      calls.add BatchCall(
        seat: seat,
        system: SystemPrompt,
        user: engine.userMessage(sim, seat, turnIndex))

  # The RATE FLOOR: consecutive batch STARTS are held turnSpacingMs apart, so
  # the episode cannot exceed the hosted sidecar's 30 requests/minute cap. The
  # sleep happens on the game loop; the mummy serve thread is independent, so
  # no connection is dropped by it, and the wall-clock stop is re-checked every
  # tick afterwards.
  if calls.len > 0 and engine.hasBatched and sim.config.turnSpacingMs > 0:
    let
      due = engine.lastBatchStart +
        initDuration(milliseconds = sim.config.turnSpacingMs)
      waitMs = (due - getMonoTime()).inMilliseconds
    if waitMs > 0:
      sleep(int(min(waitMs, int64(sim.config.turnSpacingMs))))

  let deadline = getMonoTime() + initDuration(
    milliseconds = max(1, sim.config.turnBudgetMs))
  if calls.len > 0:
    engine.lastBatchStart = getMonoTime()
    engine.hasBatched = true

  var attempt = 1
  while calls.len > 0 and attempt <= 2:
    let
      remainingMs = (deadline - getMonoTime()).inMilliseconds
      wantMs = if attempt == 1: sim.config.attempt1Ms else: sim.config.retryMs
      allowedMs = min(wantMs, int(max(0'i64, remainingMs)))
    if allowedMs <= 0:
      break
    let started = getMonoTime()
    var replies: seq[BatchReply]
    try:
      # FLOOR, not ceiling: curly's timeout is whole seconds and a batch in
      # flight is not interruptible, so rounding up would let the retry run
      # past the turn budget the outer deadline is supposed to enforce.
      replies = engine.batch(calls, max(1, allowedMs div 1000))
    except CatchableError as failure:
      replies = @[]
      for call in calls:
        replies.add BatchReply(seat: call.seat, error: failure.msg)
    let latency = int32((getMonoTime() - started).inMilliseconds)
    var retry: seq[BatchCall]
    for reply in replies:
      let seat = clamp(reply.seat, 0, SeatCount - 1)
      var cause = ""
      var detail = reply.error
      if not reply.ok:
        # curl words its deadline several ways ("Timeout was reached",
        # "Operation timed out after ...", "Connection timed out"), so match on
        # the lowercased text and on both spellings.
        let text = reply.error.toLowerAscii()
        cause =
          if text.contains("timeout") or text.contains("timed out"): "timeout"
          elif text.contains("throttled") or text.contains("429"): "throttled"
          else: "transport_error"
      else:
        try:
          let payload = extractJsonObject(reply.text)
          let parsed = parseDirective(sim, seat, payload,
            engine.previous[seat], engine.hasPrevious[seat],
            sim.zonalDirective(seat, turnIndex), turnIndex)
          if parsed.usable:
            resolved[seat] = parsed.directive
            resolved[seat].latencyMs = latency
            settled[seat] = true
          else:
            cause = "parse_error"
            detail = "no usable cog entry"
        except CatchableError as failure:
          cause = "parse_error"
          detail = failure.msg
      if cause.len > 0:
        engine.addRecord(%*{
          "k": "fallback", "turn": turnIndex, "seat": seat,
          "attempt": attempt, "cause": cause,
          "detail": clipRunes(detail, MaxDetailRunes)
        })
        for call in calls:
          if call.seat == reply.seat:
            retry.add call
    calls = retry
    inc attempt

  for call in calls:
    # Two consecutive failures: the seat plays `zonal` this turn.
    let seat = clamp(call.seat, 0, SeatCount - 1)
    resolved[seat] = engine.fallbackFor(sim, seat, turnIndex)
    settled[seat] = true

  for seat in 0 ..< SeatCount:
    if not settled[seat]:
      resolved[seat] = engine.fallbackFor(sim, seat, turnIndex)
    resolved[seat].turn = int32(turnIndex)
    resolved[seat].half = sim.half
    sim.activeDirective[seat] = resolved[seat]
    sim.hasDirective[seat] = true
    engine.previous[seat] = resolved[seat]
    engine.hasPrevious[seat] = true
    case resolved[seat].source
    of dsLlm: inc sim.seatStats[seat].llmTurns
    of dsFallback: inc sim.seatStats[seat].fallbackTurns
    of dsScripted: discard
    # The record is the ONE source: the server writes it to the replay AND
    # folds it back through `applyRecord`, so the feed reads identically live
    # and in playback.
    engine.addRecord(directiveJson(seat, resolved[seat]))

  for i in 0 ..< CogCount:
    engine.lastCogStats[i] = sim.cogStats[i]
  for team in Team:
    engine.lastTeamStats[team] = sim.teamStats[team]
  engine.lastGoals.setLen(0)
