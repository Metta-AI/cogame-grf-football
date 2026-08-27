## The manifest contract: `num_agents` is 8 everywhere it must be and nowhere
## it must not, the replay viewer is the static bundle, both protocols are
## declared, the docs are inlined as TEXT, and the results schema's keys equal
## `playerResultsJson()`'s keys exactly.

import std/[json, os, sequtils, sets, strutils]
import lib/helpers

const ManifestPath = "coworld_manifest_template.json"

proc manifest(): JsonNode =
  doAssert fileExists(ManifestPath)
  parseJson(readFile(ManifestPath))

proc numAgentsEverywhere() =
  let m = manifest()
  doAssert m["variants"].len >= 2, "at least the match and half variants"
  for variant in m["variants"]:
    doAssert not variant.hasKey("num_agents"),
      "num_agents at a variant's TOP LEVEL is rejected by CoworldVariant"
    let config = variant["game_config"]
    doAssert config["num_agents"].getInt == SeatCount,
      "variant " & variant["id"].getStr & " must seat " & $SeatCount
    doAssert config["players"].len == SeatCount
    doAssert config["slots"].len == SeatCount
    for i in 0 ..< SeatCount:
      doAssert config["slots"][i]["team"].getStr == teamText(teamOfSeat(i)),
        "seat parity IS the team"
  let cert = m["certification"]
  doAssert cert["game_config"]["num_agents"].getInt == SeatCount
  doAssert cert["players"].len == SeatCount
  doAssert cert["game_config"]["players"].len == SeatCount
  doAssert cert["game_config"]["turnSpacingMs"].getInt == 0,
    "the cert fixture pays no rate floor"
  report "num_agents is 8 in every variant's game_config and in the fixture"

proc replayViewerIsTheStaticBundle() =
  let m = manifest()
  doAssert m["game"]["replay_viewer"]["bundle"].getStr ==
    "static-replay-viewer"
  doAssert not m["game"].hasKey("display_name")
  doAssert not m.hasKey("version"), "no top-level version (coworld 0.1.42)"
  doAssert m["game"].hasKey("owner")
  doAssert m["game"].hasKey("description")
  doAssert not m["game"].hasKey("tags"), "tags live top-level only"
  doAssert m["tags"].len >= 3
  doAssert m["game"]["runnable"]["type"].getStr == "game"
  report "the replay viewer is declared as the static bundle"

proc protocolsAndDocs() =
  let m = manifest()
  for key in ["player", "global"]:
    doAssert m["game"]["protocols"].hasKey(key),
      "game.protocols must carry BOTH player and global"
    let node = m["game"]["protocols"][key]
    doAssert node.hasKey("type") and node.hasKey("value")
    doAssert node["value"].getStr.len > 0
  let docs = m["game"]["docs"]
  doAssert docs["readme"]["type"].getStr == "text"
  doAssert docs["readme"]["value"].getStr.len > 500,
    "the README is inlined as TEXT, not a URI"
  doAssert docs["pages"].len == 3
  for page in docs["pages"]:
    doAssert page.hasKey("id") and page.hasKey("title")
    doAssert page["content"]["type"].getStr == "text"
    doAssert page["content"]["value"].getStr.len > 500,
      "doc page " & page["id"].getStr & " is empty"
  report "both protocols are declared and all four docs are non-empty text"

proc resultsSchemaMatchesTheDocument() =
  let m = manifest()
  let schema = m["game"]["results_schema"]
  doAssert not schema["additionalProperties"].getBool
  var declared = initHashSet[string]()
  for key, _ in schema["properties"]:
    declared.incl(key)
  var produced = initHashSet[string]()
  let sim = seatedSim(testConfig())
  for key, _ in parseJson(sim.playerResultsJson()):
    produced.incl(key)
  doAssert declared == produced,
    "results_schema and playerResultsJson() disagree: schema-only " &
      $(declared - produced) & ", document-only " & $(produced - declared)
  for key in ["names", "scores", "win", "team", "reason", "endRule"]:
    doAssert key in schema["required"].getElems.mapIt(it.getStr),
      key & " must be required"
  report "results_schema's keys equal playerResultsJson()'s keys exactly"

proc configSchemaCoversTheConfig() =
  let m = manifest()
  let props = m["game"]["config_schema"]["properties"]
  # Every key the resolved config echoes that a variant may also set.
  for key in ["seed", "num_agents", "minPlayers", "maxTicks", "halfTicks",
      "maxGames", "turnTicks", "turnBudgetMs", "attempt1Ms", "retryMs",
      "turnSpacingMs", "wallClockBudgetSeconds", "lobbyJoinTimeoutTicks",
      "startWaitTicks", "gameOverTicks", "mercyGoalDiff", "restartTicks",
      "stalemateTicks", "fastMode", "showPlayerLabels", "closedRoster",
      "model", "maxOutputTokens", "speed", "baseSpeed", "sprintSpeed",
      "shotSpeed", "shortPassSpeed", "longPassSpeed", "players", "slots",
      "tokens"]:
    doAssert props.hasKey(key), "config_schema is missing " & key
  # Every ARRAY property needs minItems and maxItems, or certification fails.
  for key, value in props:
    if value{"type"}.getStr == "array":
      doAssert value.hasKey("minItems") and value.hasKey("maxItems"),
        "array property " & key & " needs minItems/maxItems bounds"
  # Every variant's game_config must be a legal config for the engine.
  for variant in m["variants"]:
    var config = defaultGameConfig()
    var node = copy(variant["game_config"])
    var tokens = newJArray()
    for i in 0 ..< SeatCount:
      tokens.add(%("token-" & $i))
    node["tokens"] = tokens
    config.update($node)
    doAssert config.numAgents == SeatCount
  var certConfig = defaultGameConfig()
  var certNode = copy(m["certification"]["game_config"])
  var certTokens = newJArray()
  for i in 0 ..< SeatCount:
    certTokens.add(%("token-" & $i))
  certNode["tokens"] = certTokens
  certConfig.update($certNode)
  doAssert certConfig.maxTicks == 1440
  report "config_schema covers the config and every variant validates"

proc certFixtureFitsTheCertifierClock() =
  ## `coworld certify` defaults to a 60 s timeout covering start + connect
  ## grace + the episode + the post-game linger. The fixture must fit.
  let m = manifest()
  let cert = m["certification"]["game_config"]
  let
    ticks = cert["maxTicks"].getInt
    seconds = ticks div TargetFps
  doAssert seconds <= 60,
    "the cert fixture is " & $seconds & " s of sim; size it under the clock"
  doAssert cert["turnSpacingMs"].getInt == 0
  doAssert cert["fastMode"].getBool
  report "the certification fixture fits inside the certifier's clock"

proc bundledPlayerResources() =
  let m = manifest()
  doAssert m["player"].len >= 1
  for entry in m["player"]:
    doAssert entry["type"].getStr == "player"
    doAssert entry.hasKey("id") and entry.hasKey("name") and
      entry.hasKey("description")
    doAssert entry["run"][0].getStr == "/bin/grf-football-player"
    doAssert entry["resources"]["limits"]["cpu"].getStr == "1",
      "the bundled player cpu limit minimum is \"1\""
  var declared: seq[string]
  for entry in m["player"]:
    declared.add(entry["id"].getStr)
  var seated: seq[string]
  for entry in m["certification"]["players"]:
    seated.add(entry["player_id"].getStr)
  for id in declared:
    doAssert id in seated,
      "every declared player must occupy a certification slot: " & id
  report "the bundled player is declared, resourced and seated"

proc secretNamespaceIsTheGameName() =
  let m = manifest()
  let env = m["game"]["runnable"]["env"]
  doAssert env.hasKey("ANTHROPIC_API_KEY_URI"),
    "without this the hosted game pod never receives the secret and every " &
      "league episode silently plays scripted"
  doAssert env["ANTHROPIC_API_KEY_URI"].getStr ==
    "secret://coworld/" & m["game"]["name"].getStr & "/anthropic_api_key",
    "the secret namespace must equal game.name exactly"
  report "the game runnable carries the anthropic secret URI at game.name"

when isMainModule:
  echo "test_manifest"
  numAgentsEverywhere()
  replayViewerIsTheStaticBundle()
  protocolsAndDocs()
  resultsSchemaMatchesTheDocument()
  configSchemaCoversTheConfig()
  certFixtureFitsTheCertifierClock()
  bundledPlayerResources()
  secretNamespaceIsTheGameName()
  echo "test_manifest ok"
