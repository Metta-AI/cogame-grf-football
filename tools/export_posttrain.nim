## Complete private candidates; independent review owns training admission.
import std/[json, os, osproc, strutils]
import grf_football/[sim, roster, baselines, directives, control, decide, prompts, evidence]

const OperatorPrompt = "Play your shirt using the match view and coordinate through the ball."

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "match"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert matches >= 10 and firstSeed >= 1
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  writePrivate(output / "execution.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let execution = open(output / "execution.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in firstSeed ..< firstSeed + matches:
      var config = defaultGameConfig()
      config.update($variantConfig)
      config.seed = seed
      var state = initSimServer(config)
      state.gameEventLoggingEnabled = false
      for seat in 0 ..< SeatCount:
        discard state.addPlayer("policy-" & $seat, seat, "", trusted = true)
      let family = "grf-football-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      var engine = newTurnEngine(nil, nil, selection)
      var previousActions = newSeq[uint8](CogCount)
      var lastTurn = -1
      var lastGoals: array[Team, int32]
      var count = 0
      for seat in 0 ..< SeatCount: engine.policies[seat].prompt = OperatorPrompt
      while state.phase != GameOver:
        if state.phase == Playing:
          let turn = state.gameTicksElapsed() div state.turnTicks()
          if turn != lastTurn:
            lastTurn = turn
            var pending: array[SeatCount, Directive]
            for seat in 0 ..< SeatCount:
              let system = selection.systemMessage()
              let user = engine.userMessage(state, seat, turn)
              var view = engine.seatViewJson(state, seat, turn)
              view["prompt_template"] = selection.promptMetadata(system, user)
              let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
              let teacher = state.zonalDirective(seat, turn)
              let record = directiveJson(seat, teacher)
              let proposal = %*{"note": record["note"], "cogs": record["cogs"]}
              let parsed = state.parseDirective(seat, proposal,
                engine.previous[seat], engine.hasPrevious[seat], teacher, turn)
              doAssert parsed.usable
              pending[seat] = parsed.directive
              let installedRecord = directiveJson(seat, parsed.directive)
              let installed = %*{"note": installedRecord["note"], "cogs": installedRecord["cogs"]}
              let accepted = proposal == installed
              let id = count
              inc count
              let attemptId = $id & "-teacher"
              stream.writeLine($(%*{
                "schema_version": "1", "event_type": "decision", "episode_id": episode,
                "decision_id": $id, "decision_index": id, "game": "grf-football",
                "game_version": "source-" & revision, "source_revision": revision,
                "seat": $seat, "visibility": "private", "observation": view,
                "prompt": (if accepted: messages else: newJNull()),
                "attempts": [{"attempt_id": attemptId, "policy": "scripted-zonal",
                  "origin": "teacher", "inference_mode": "text_action", "prompt": messages,
                  "response": $proposal, "parsed_action": proposal, "accepted": accepted,
                  "request": newJNull(), "platform_call_id": newJNull(), "behavior_logprobs": newJNull(),
                  "rejection_reason": (if accepted: newJNull() else: %"engine-normalized-submission")}],
                "selected_attempt_id": (if accepted: %attemptId else: newJNull()),
                "executed_action": installed, "action_status": (if accepted: "accepted" else: "fallback"),
                "fallback_origin": (if accepted: newJNull() else: %"engine-normalized-submission"),
                "terminal": false}))
            var orders = newJArray()
            for seat in 0 ..< SeatCount:
              state.activeDirective[seat] = pending[seat]
              state.hasDirective[seat] = true
              engine.previous[seat] = pending[seat]
              engine.hasPrevious[seat] = true
              orders.add(directiveJson(seat, pending[seat]))
            execution.writeLine($(%*{"event_type": "turn_execution", "visibility": "private",
              "episode_id": episode, "turn": turn, "tick": state.tickCount,
              "first_decision_id": count - SeatCount, "orders": orders}))
            for index in 0 ..< CogCount: engine.lastCogStats[index] = state.cogStats[index]
            for team in Team: engine.lastTeamStats[team] = state.teamStats[team]
            engine.lastGoals.setLen(0)
        let actions = state.compileActions(state.activeDirective)
        var buffer = newSeq[uint8](CogCount)
        for index in 0 ..< CogCount: buffer[index] = actions[index]
        let beforeHash = state.gameHash()
        state.step(buffer, previousActions)
        previousActions = buffer
        execution.writeLine($(%*{"event_type": "tick_execution", "visibility": "private",
          "episode_id": episode, "tick": state.tickCount, "actions": buffer,
          "before_hash": $beforeHash, "after_hash": $state.gameHash()}))
        for team in Team:
          if state.teamStats[team].goals > lastGoals[team]:
            lastGoals[team] = state.teamStats[team].goals
            engine.noteGoal(state.tickCount, int(state.lastGoalBy), team)
      let outcome = parseJson(state.playerResultsJson())
      doAssert count > 0 and outcome["reason"].getStr() == "complete"
      var participants = newJObject()
      for seat in 0 ..< SeatCount: participants[$seat] = %*{"score": outcome["scores"][seat]}
      stream.writeLine($(%*{"schema_version": "1", "event_type": "episode",
        "episode_id": episode, "seed_family": family, "game": "grf-football",
        "game_version": "source-" & revision, "source_revision": revision,
        "status": "completed", "outcome": outcome, "participant_outcomes": participants}))
      runs.add(%*{"seed": seed, "decisions": count, "team_goals": outcome["teamGoals"], "reason": outcome["reason"]})
  finally:
    stream.close()
    execution.close()
  writePrivate(output / "manifest.json", pretty(%*{"schema_version": 1,
    "game": "grf-football", "variant": variant, "source_revision": revision,
    "teacher": "scripted-zonal", "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "execution_evidence": "execution.jsonl", "runs": runs}) & "\n")
  echo "complete matches=", matches
