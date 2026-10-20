## Complete football matches through the language decision protocol.
import std/[json, os]
import grf_football/[sim, roster, control, directives, baselines, decide, prompts]

const OperatorPrompt = "Play your shirt using the match view and coordinate through the ball."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value: hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc advance(sim: var SimServer, engine: TurnEngine, previous: var seq[uint8],
    goals: var array[Team, int32], lastTurn: int) =
  while sim.phase != GameOver:
    if sim.phase == Playing and sim.gameTicksElapsed() div sim.turnTicks() > lastTurn:
      return
    let actions = sim.compileActions(sim.activeDirective)
    var buffer = newSeq[uint8](CogCount)
    for index in 0 ..< CogCount: buffer[index] = actions[index]
    sim.step(buffer, previous)
    previous = buffer
    for team in Team:
      if sim.teamStats[team].goals > goals[team]:
        goals[team] = sim.teamStats[team].goals
        engine.noteGoal(sim.tickCount, int(sim.lastGoalBy), team)

proc observation(sim: SimServer, engine: TurnEngine, seat, id: int): JsonNode =
  if sim.phase == GameOver:
    let outcome = parseJson(sim.playerResultsJson())
    var scores = newJObject()
    for slot in 0 ..< SeatCount: scores[$slot] = outcome["scores"][slot]
    return %*{"kind": "terminal", "scores": scores}
  let turn = sim.gameTicksElapsed() div sim.turnTicks()
  let system = engine.selection.systemMessage()
  let user = engine.userMessage(sim, seat, turn)
  let view = engine.seatViewJson(sim, seat, turn)
  view["prompt_template"] = engine.selection.promptMetadata(system, user)
  %*{"kind": "decision", "game": "grf-football", "decision_id": id,
    "seat": seat, "engine_seat": seat, "turn": turn, "semantic_view": view,
    "inbox": [], "messages": [{"role": "system", "content": system},
      {"role": "user", "content": user}], "speech_messages": [],
    "action_schema": {"type": "object", "required": ["cogs"],
      "properties": {"note": {"type": "string"}, "cogs": {"type": "array"}}},
    "typed_question": newJNull()}

when isMainModule:
  let args = commandLineParams()
  doAssert args.len in 1 .. 2, "usage: football-bridge MANIFEST [match|half]"
  let variant = if args.len == 2: args[1] else: "match"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var state: SimServer
  var engine: TurnEngine
  var previousActions: seq[uint8]
  var goals: array[Team, int32]
  var pending: array[SeatCount, Directive]
  var seat, id: int
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == SeatCount
      let selection = promptSelection(request)
      if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference} and
          (not request.hasKey("split") or request["split"].getStr() notin ["evaluation", "validation", "test"]):
        raise newException(ValueError, "held-out wording requires an explicit evaluation split")
      var config = defaultGameConfig()
      config.update($variantConfig)
      config.seed = seedOf(request["seed"].getStr())
      state = initSimServer(config)
      state.gameEventLoggingEnabled = false
      for slot in 0 ..< SeatCount:
        discard state.addPlayer("policy-" & $slot, slot, "", trusted = true)
      engine = newTurnEngine(nil, nil, selection)
      for slot in 0 ..< SeatCount: engine.policies[slot].prompt = OperatorPrompt
      previousActions = newSeq[uint8](CogCount)
      goals = default(array[Team, int32])
      seat = 0
      id = 0
      state.advance(engine, previousActions, goals, -1)
      response = state.observation(engine, seat, id)
    of "teacher":
      doAssert state.phase != GameOver
      let turn = state.gameTicksElapsed() div state.turnTicks()
      let record = directiveJson(seat, state.zonalDirective(seat, turn))
      response = %*{"response": $(%*{"note": record["note"], "cogs": record["cogs"]})}
    of "step":
      doAssert state.phase != GameOver and request["decision_id"].getInt() == id
      let turn = state.gameTicksElapsed() div state.turnTicks()
      let parsed = state.parseDirective(seat, parseJson(request["response"].getStr()),
        engine.previous[seat], engine.hasPrevious[seat], state.zonalDirective(seat, turn), turn)
      doAssert parsed.usable
      pending[seat] = parsed.directive
      let record = directiveJson(seat, parsed.directive)
      let action = %*{"note": record["note"], "cogs": record["cogs"]}
      inc id
      inc seat
      if seat == SeatCount:
        for slot in 0 ..< SeatCount:
          state.activeDirective[slot] = pending[slot]
          state.hasDirective[slot] = true
          engine.previous[slot] = pending[slot]
          engine.hasPrevious[slot] = true
        for index in 0 ..< CogCount: engine.lastCogStats[index] = state.cogStats[index]
        for team in Team: engine.lastTeamStats[team] = state.teamStats[team]
        engine.lastGoals.setLen(0)
        state.advance(engine, previousActions, goals, turn)
        seat = 0
      response = %*{"kind": "accepted", "action": action,
        "observation": state.observation(engine, seat, id)}
    else:
      raise newException(ValueError, "unknown bridge command")
    stdout.writeLine($response)
    stdout.flushFile()
