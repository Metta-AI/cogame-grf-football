## TWO NAME SPACES. In-game everything is `RED-9`; real policy names appear
## only in the replay config, `roster[].name`, `teams.*.policies` and
## `results.names`.

import std/[json, strutils]
import lib/helpers

const RealNames = ["policy-0", "policy-1", "policy-2", "policy-3",
                   "policy-4", "policy-5", "policy-6", "policy-7"]

proc matchesAlias(id: string): bool =
  ## `^(RED|BLUE)-([1-9]|1[01])$`, hand-rolled: std/re would pull PCRE in for
  ## one predicate, and this is the only pattern the suite needs.
  let cut = id.find('-')
  if cut <= 0 or cut == id.high:
    return false
  let prefix = id[0 ..< cut]
  if prefix != "RED" and prefix != "BLUE":
    return false
  let digits = id[cut + 1 .. id.high]
  if digits.len == 0 or digits.len > 2:
    return false
  if digits[0] == '0':
    return false
  for ch in digits:
    if ch notin {'0' .. '9'}:
      return false
  let n = parseInt(digits)
  n >= 1 and n <= CogsPerTeam

proc aliasPattern() =
  for i in 0 ..< CogCount:
    doAssert matchesAlias(cogId(i)), "bad in-game id " & cogId(i)
  doAssert not matchesAlias("RED-12")
  doAssert not matchesAlias("GREEN-1")
  doAssert not matchesAlias("daveey")
  report "every in-game id matches ^(RED|BLUE)-([1-9]|1[01])$"

proc seatViewsCarryNoRealName() =
  var sim = playing(testConfig())
  # showPlayerLabels is forced TRUE here: the guarantee must be the VOCABULARY,
  # not the flag.
  sim.config.showPlayerLabels = true
  let engine = newTurnEngine(nil, nil)
  for seat in 0 ..< SeatCount:
    let view = $engine.seatViewJson(sim, seat, 3)
    for name in RealNames:
      doAssert name notin view,
        "seat " & $seat & "'s view leaks the real policy name " & name
    doAssert cogId(cogOfSeat(seat)) in view,
      "a seat's view names its own shirt"
  report "no seat view carries a real policy name, even with labels forced on"

proc directiveRecordsCarryNoRealName() =
  var sim = playing(testConfig())
  for seat in 0 ..< SeatCount:
    for name in ["zonal", "gegenpress"]:
      let record = $directiveJson(seat, sim.baselineDirective(seat, name, 1))
      for real in RealNames:
        doAssert real notin record,
          "a directive record leaks " & real
  report "no directive record carries a real policy name"

proc broadcastKeepsThemApart() =
  var sim = playing(testConfig())
  let state = parseJson(sim.buildStateJson(newJArray(), true, 1, 100, false,
    true, -1, -1))
  # Spectator side: the roster and the team policy lists DO carry real names.
  var sawReal = false
  for entry in state["roster"]:
    if entry["name"].getStr in RealNames:
      sawReal = true
    doAssert entry["alias"].getStr.startsWith("RED-") or
      entry["alias"].getStr.startsWith("BLUE-"),
      "the roster's in-game alias is a shirt id"
  doAssert sawReal, "the spectator roster DOES carry the real names"
  doAssert state["teams"]["red"]["policies"].len > 0
  report "the broadcast frame keeps the two name spaces apart"

proc boardLabelsAreAliasesOnly() =
  ## Board labels are built from `cogId()` alone, so there is no code path that
  ## could put a real name on the board. Assert it on the SOURCE.
  let source = strippedSource("src/grf_football/global.nim")
  doAssert "address" notin identifiers(source),
    "global.nim must never read a player's address"
  doAssert "policyLabel" notin identifiers(source),
    "global.nim must never read a policy label"
  report "the board renderer cannot reach a real policy name"

when isMainModule:
  echo "test_identity_privacy"
  aliasPattern()
  seatViewsCarryNoRealName()
  directiveRecordsCarryNoRealName()
  broadcastKeepsThemApart()
  boardLabelsAreAliasesOnly()
  echo "test_identity_privacy ok"
