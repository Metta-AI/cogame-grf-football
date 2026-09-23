## Export complete football matches as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT MATCHES [FIRST_SEED] [match|half]

import std/[json, os, osproc, strutils]
import grf_football/[sim, roster, baselines, directives, control, decide]

const OperatorPrompt = "Play your shirt using the match view and coordinate through the ball."

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT MATCHES [FIRST_SEED] [match|half]", 1)
  let output = args[0]
  let matches = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: "match"
  if matches < 10 or firstSeed < 1:
    quit("at least ten matches and a positive first seed are required", 1)
  if variant notin ["match", "half"]:
    quit("variant must be match or half", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + matches:
    var config = defaultGameConfig()
    config.update($variantConfig)
    config.seed = seed
    var sim = initSimServer(config)
    sim.gameEventLoggingEnabled = false
    for seat in 0 ..< SeatCount:
      discard sim.addPlayer("policy-" & $seat, seat, "", trusted = true)
    var
      engine = newTurnEngine(nil, nil)
      previousActions = newSeq[uint8](CogCount)
      rows: seq[string]
      lastTurn = -1
      lastGoals: array[Team, int32]
    for seat in 0 ..< SeatCount:
      engine.policies[seat].prompt = OperatorPrompt
    while sim.phase != GameOver:
      if sim.phase == Playing:
        let turn = sim.gameTicksElapsed() div sim.turnTicks()
        if turn != lastTurn:
          lastTurn = turn
          for seat in 0 ..< SeatCount:
            let view = engine.userMessage(sim, seat, turn)
            let teacher = sim.zonalDirective(seat, turn)
            let record = directiveJson(seat, teacher)
            let completion = %*{"note": record["note"],
              "cogs": record["cogs"]}
            let parsed = sim.parseDirective(seat, completion,
              engine.previous[seat], engine.hasPrevious[seat], teacher, turn)
            doAssert parsed.usable
            doAssert directiveJson(seat, parsed.directive)["cogs"] ==
              completion["cogs"]
            rows.add($(%*{
              "episode_id": "grf-football-" & variant & "-" & $seed,
              "seed": "grf-football-" & variant & "-" & $seed,
              "decision_id": turn * SeatCount + seat,
              "prompt": [
                {"role": "system", "content": SystemPrompt},
                {"role": "user", "content": view}
              ],
              "completion": [{"role": "assistant", "content": $completion}],
              "game": "grf-football",
              "action_schema_revision": "football-directive-v1"
            }))
            sim.activeDirective[seat] = parsed.directive
            sim.hasDirective[seat] = true
            engine.previous[seat] = parsed.directive
            engine.hasPrevious[seat] = true
          for i in 0 ..< CogCount:
            engine.lastCogStats[i] = sim.cogStats[i]
          for team in Team:
            engine.lastTeamStats[team] = sim.teamStats[team]
          engine.lastGoals.setLen(0)
      let actions = sim.compileActions(sim.activeDirective)
      var buffer = newSeq[uint8](CogCount)
      for i in 0 ..< CogCount:
        buffer[i] = actions[i]
      sim.step(buffer, previousActions)
      previousActions = buffer
      for team in Team:
        if sim.teamStats[team].goals > lastGoals[team]:
          lastGoals[team] = sim.teamStats[team].goals
          engine.noteGoal(sim.tickCount, int(sim.lastGoalBy), team)
    doAssert rows.len > 0
    let outcome = parseJson(sim.playerResultsJson())
    doAssert outcome["reason"].getStr() == "complete"
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "team_goals": outcome["teamGoals"], "reason": outcome["reason"]})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "grf-football",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-zonal",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
