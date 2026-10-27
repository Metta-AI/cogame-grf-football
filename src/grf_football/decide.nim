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
  sim, directives, baselines, builtin_ai, llm, prompts, capture

const CanonicalBriefing = """You control ONE shirt. Seven of your teammates are run by the engine's built-in AI:
they hold a 4-3-3 shape, tackle when the ball is at their feet, pass to the nearest
better-placed teammate, and never dribble far. Three other shirts on your team are
controlled by other policies you cannot talk to.
Every 10 seconds of match time you issue ONE order for your shirt. A deterministic
controller executes it for the next 10 seconds: it steers your cog, sprints, tackles
and plays the ball for you according to your order.
The pitch is 84 by 54 metres. You attack toward the goal named in "attacking_goal".
The ball goes OUT: throw-ins, corners and goal kicks are real. There is no offside.
A slide tackle that misses the ball and hits the opponent is a foul: you lose the
ball and lie grounded for two seconds. Sprinting drains stamina; low stamina slows you
until it recovers.
"""

const ReplyRules = """Reply with a single JSON object and NOTHING else. Your reply MUST begin with '{'.
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

proc systemMessage*(selection: PromptSelection): string =
  result = selection.introduction() & "\n"
  case selection.selectedVariant
  of pvCanonical: result.add(CanonicalBriefing)
  of pvPlain:
    result.add("Control just your own shirt. Seven teammates use built-in AI: they keep a 4-3-3 shape, " &
      "tackle at the ball, pass to a nearby better-placed teammate, and avoid long dribbles. Three " &
      "teammates belong to other policies, with no chat between you. Give one order every 10 " &
      "seconds of match time; a deterministic controller follows it for the next 10 seconds, " &
      "handling movement, sprinting, tackles, and on-ball play. The pitch measures 84 × 54 metres; " &
      "attack the goal in \"attacking_goal\". The ball can go out for throw-ins, corners, or goal " &
      "kicks, and there is no offside. Sliding into an opponent without reaching the ball is a " &
      "foul: you lose the ball and are grounded for two seconds. Sprinting drains stamina; low " &
      "stamina slows you until it recovers.\n")
  of pvNumbered:
    result.add("1. Responsibility: one shirt. Seven teammates are built-in AI, keeping a 4-3-3, tackling at " &
      "the ball, passing to the nearest better-placed teammate, and avoiding long dribbles.\n2. " &
      "Partners: three other policy-controlled teammates; no communication channel.\n3. Cadence: " &
      "one order each 10 seconds of match time. The deterministic controller executes steering, " &
      "sprinting, tackling, and ball play for the following 10 seconds.\n4. Pitch: 84 × 54 metres; " &
      "your goal to attack is \"attacking_goal\".\n5. Boundaries: throw-ins, corners, and goal kicks " &
      "apply. No offside.\n6. Foul: a slide that misses the ball and hits an opponent loses the " &
      "ball and grounds you for two seconds.\n7. Fatigue: sprinting consumes stamina; reduced speed " &
      "lasts until low stamina recovers.\n")
  of pvQuestions:
    result.add("Who do you command? One shirt. Who runs the others? Built-in AI controls seven teammates in " &
      "a 4-3-3: tackle at the ball, pass to the nearest better-positioned teammate, and do not " &
      "dribble far. Three teammates use other policies you cannot talk to. How often do you act? " &
      "One order every 10 match seconds; a deterministic controller steers, sprints, tackles, and " &
      "plays the ball for the next 10 seconds. Where do you play? An 84 × 54 metre pitch, " &
      "attacking \"attacking_goal\". What happens out of bounds? Throw-ins, corners, and goal kicks; " &
      "no offside. What if a slide hits an opponent but misses the ball? A foul, loss of the ball, " &
      "and two seconds grounded. Why limit sprinting? It drains stamina and low stamina slows you " &
      "until recovery.\n")
  of pvReordered:
    result.add("Sprint carefully: it drains stamina, and low stamina reduces speed until recovery. A slide " &
      "that misses the ball and hits an opponent is a foul, losing the ball and grounding you for " &
      "two seconds. There is no offside, but throw-ins, corners, and goal kicks apply on the 84 × " &
      "54 metre pitch; attack \"attacking_goal\". You control one shirt through one order each 10 " &
      "match seconds. A deterministic controller executes its steering, sprinting, tackles, and " &
      "ball play over the following 10 seconds. Seven teammates use built-in AI: a 4-3-3 shape, " &
      "tackles at the ball, passes to the nearest better-placed teammate, and short dribbles. " &
      "Three other shirts use policies you cannot talk to.\n")
  of pvHeldoutBriefing:
    result.add("Act as one shirt in a team with seven built-in teammates and three other policy-controlled " &
      "teammates. The built-in players keep a 4-3-3, tackle at the ball, pass to the nearest " &
      "better-placed teammate, and do not dribble far; you cannot talk to the other policies. " &
      "Every 10 seconds of match time, send one order. A deterministic controller carries out " &
      "movement, sprinting, tackles, and ball play for the next 10 seconds. Use the 84 × 54 metre " &
      "pitch and attack the goal identified by \"attacking_goal\". Out-of-play balls produce " &
      "throw-ins, corners, or goal kicks; offside is absent. A slide missing the ball and hitting " &
      "an opponent is a foul: possession is lost and you are grounded for two seconds. Sprinting " &
      "spends stamina; low stamina slows you until it recovers.\n")
  of pvHeldoutReference:
    result.add("Controlled unit: one shirt. Built-in teammates: seven; 4-3-3 shape, tackle at ball, pass to " &
      "nearest better-placed teammate, no long dribbles. Other policy teammates: three, no chat. " &
      "Order interval: 10 match seconds. Execution: deterministic steering/sprint/tackle/ball play " &
      "over the next 10 seconds. Pitch: 84 × 54 metres. Attack direction: \"attacking_goal\". " &
      "Out-of-play rules: throw-ins, corners, goal kicks. Offside: none. Slide into opponent " &
      "without reaching ball: foul, lost possession, two seconds grounded. Sprint cost: stamina; " &
      "low-stamina speed loss lasts until recovery.\n")
  of pvMixed: raise newException(ValueError, "mixed selection must resolve")
  result.add(ReplyRules)

type
  BatchCall* = object
    seat*: int
    system*, user*: string

  BatchReply* = object
    seat*: int
    ok*: bool
    text*: string
    error*: string
    evidence*: DecisionAttempt

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
    trajectory*: DecisionTrajectory
    selection*: PromptSelection
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
    var evidence: seq[DecisionAttempt]
    for call in calls:
      let request = client.requestFor(call.system, call.user, call.seat)
      evidence.add(requestEvidence("pending", "prompt", call.system, call.user, request.body))
      batch.post(request.url, request.headers, request.body, $call.seat)
    let responses = client.curl.makeRequests(batch, max(1, timeoutSeconds))
    for i, call in calls:
      var reply = BatchReply(seat: call.seat)
      reply.evidence = evidence[i]
      if i >= responses.len:
        reply.error = "no response"
        result.add(reply)
        continue
      let (response, error) = responses[i]
      reply.evidence.receivedEvidence(response)
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

proc newTurnEngine*(client: LlmClient, batch: BatchFn, selection: PromptSelection): TurnEngine =
  result = TurnEngine(client: client, batch: batch, guardTurn: -1, selection: selection)
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
  var observations: array[SeatCount, JsonNode]
  for seat in 0 ..< SeatCount:
    observations[seat] = engine.seatViewJson(sim, seat, turnIndex)
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
    attempts: array[SeatCount, seq[DecisionAttempt]]
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
        system: systemMessage(engine.selection),
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
      var receipt = reply.evidence
      receipt.attemptId = $turnIndex & "-" & $seat & "-" & $attempt
      receipt.policy = engine.policies[seat].label
      receipt.latencyMs = some(float(latency))
      receipt.response = %reply.text
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
            receipt.accepted = true
          else:
            cause = "parse_error"
            detail = "no usable cog entry"
        except CatchableError as failure:
          cause = "parse_error"
          detail = failure.msg
      if cause.len > 0:
        receipt.rejectionReason = some(cause & ": " & detail)
      attempts[seat].add(receipt)
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
    let action = directiveJson(seat, resolved[seat])
    engine.addRecord(action)
    if not engine.trajectory.isNil:
      var selected = none(string)
      var status = asFallback
      if resolved[seat].source == dsLlm:
        status = asAccepted
        for receipt in attempts[seat].mitems:
          if receipt.accepted:
            receipt.parsedAction = action
            selected = some(receipt.attemptId)
      elif resolved[seat].source == dsScripted:
        var receipt = newDecisionAttempt($turnIndex & "-" & $seat & "-scripted",
          engine.policies[seat].label, aoUnknown)
        receipt.accepted = true
        receipt.parsedAction = action
        selected = some(receipt.attemptId)
        attempts[seat].add(receipt)
        status = asAccepted
      engine.trajectory.recordDecision($turnIndex & "-" & $seat, $seat,
        observations[seat], attempts[seat], selected, action, status,
        fallbackOrigin = (if status == asFallback: some("engine_scripted") else: none(string)))

  for i in 0 ..< CogCount:
    engine.lastCogStats[i] = sim.cogStats[i]
  for team in Team:
    engine.lastTeamStats[team] = sim.teamStats[team]
  engine.lastGoals.setLen(0)
