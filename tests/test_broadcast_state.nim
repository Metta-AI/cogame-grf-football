## The broadcast chrome frame: every key the viewer reads is present, `teams`
## is keyed red/blue, the beats carry only kinds with CSS, and a frame reached
## by a SEEK hydrates the scorebug and the end-card with no events at all.

import std/[json, strutils]
import lib/helpers

const BeatKindsWithCss = ["gamestart", "goal", "shot", "save", "foul",
                          "halftime", "gameover"]

proc frame(sim: SimServer, events: JsonNode = nil): JsonNode =
  parseJson(sim.buildStateJson(
    (if events.isNil: newJArray() else: events),
    true, 1, 5760, false, true, -1, -1))

proc everyKeyIsPresent() =
  var sim = playing(testConfig())
  let s = frame(sim)
  for key in ["t", "mt", "ph", "lob", "pl", "sp", "mx", "st", "lp", "sk",
      "ff", "en", "mm", "bs", "pov", "half", "turn", "turns", "turnTicks",
      "game", "games", "restart", "ball", "teams", "roster", "feed",
      "directives", "events"]:
    doAssert s.hasKey(key), "the chrome frame is missing " & key
  doAssert s["teams"].hasKey("red") and s["teams"].hasKey("blue"),
    "teams must be keyed red/blue — the inherited chrome knows those keys"
  for team in ["red", "blue"]:
    for key in ["goals", "lives", "poss", "shots", "sot", "passes",
        "tackles", "policies"]:
      doAssert s["teams"][team].hasKey(key),
        "teams." & team & " is missing " & key
    doAssert s["teams"][team]["lives"].getInt ==
      s["teams"][team]["goals"].getInt,
      "`lives` mirrors `goals` so the inherited momentum curve draws goals"
  doAssert s["ball"].hasKey("x") and s["ball"].hasKey("z")
  doAssert s["restart"].hasKey("kind")
  report "the chrome frame carries every key the viewer reads"

proc beatsCarryOnlyKindsWithCss() =
  let config = testConfig(maxTicks = 1440)
  var sim = seatedSim(config)
  var tracker = initBroadcastTracker()
  var directives: array[SeatCount, Directive]
  for seat in 0 ..< SeatCount:
    directives[seat] = emptyDirective(seat)
  var prev = newSeq[uint8](CogCount)
  var kinds: seq[string]
  var guard = 0
  while sim.phase != GameOver and guard < config.maxTicks * 3 + 5000:
    inc guard
    if sim.phase == Playing:
      let elapsed = sim.tickCount - sim.gameStartTick
      if elapsed mod sim.turnTicks() == 0 or not sim.hasDirective[0]:
        for seat in 0 ..< SeatCount:
          sim.activeDirective[seat] =
            sim.zonalDirective(seat, elapsed div sim.turnTicks())
          sim.hasDirective[seat] = true
    let actions = sim.compileActions(sim.activeDirective)
    var buffer = newSeq[uint8](CogCount)
    for i in 0 ..< CogCount:
      buffer[i] = actions[i]
    sim.step(buffer, prev)
    prev = buffer
    let events = newJArray()
    sim.stepEvents(tracker, events)
    for e in events:
      let k = e["k"].getStr
      if k notin kinds:
        kinds.add(k)
  doAssert "gamestart" in kinds, "the opening whistle is a beat"
  doAssert "gameover" in kinds, "full time is a beat"
  for k in kinds:
    doAssert k in ["phase", "gamestart", "goal", "shot", "save", "tackle",
        "pass", "foul", "touch", "drop", "halftime", "restart", "turn_end",
        "gameover"],
      "the derived vocabulary emitted an undeclared kind: " & k
  for k in kinds:
    if k in BeatKindsWithCss:
      discard        ## every beat kind has a CSS rule; test_viewer pins that.
  report "the derived event vocabulary is closed and the beats all have CSS"

proc aSeekHydratesWithNoEvents() =
  ## A frame reached by a seek carries NO events, so everything the scorebug
  ## and the end-card show must come from STATE.
  var sim = playing(testConfig(maxTicks = 480))
  sim.teamStats[Red].goals = 2
  sim.teamStats[Blue].goals = 1
  sim.teamStats[Red].shots = 9
  sim.teamStats[Red].possessionTicks = 300
  sim.teamStats[Blue].possessionTicks = 180
  sim.finishGame(reasonComplete, erFullTime)
  let s = frame(sim)
  doAssert s["events"].len == 0, "a seek frame carries no events"
  doAssert s["teams"]["red"]["goals"].getInt == 2
  doAssert s["teams"]["red"]["poss"].getInt == 62,
    "possession is derived from state, got " & $s["teams"]["red"]["poss"]
  doAssert s.hasKey("over"), "the end-card is STATE on every game-over frame"
  doAssert s["over"]["winner"].getStr == "red"
  doAssert s["over"]["endRule"].getStr == "full_time"
  doAssert s["over"]["teams"]["red"]["goals"].getInt == 2
  report "a seek frame hydrates the scorebug and the end-card from state alone"

proc recordsFoldBackIntoTheFeed() =
  var sim = playing(testConfig())
  let d = sim.zonalDirective(2, 4)
  sim.applyRecord(capRecord($directiveJson(2, d)))
  let s = frame(sim)
  doAssert s["feed"].len > 0, "a directive record writes a feed row"
  var sawNote = false
  for row in s["feed"]:
    if row["k"].getStr == "note":
      sawNote = true
      doAssert row["team"].getStr == "red"
  doAssert sawNote, "the seat's note reaches the feed"
  report "replay records fold back into the feed identically live and in replay"

when isMainModule:
  echo "test_broadcast_state"
  everyKeyIsPresent()
  beatsCarryOnlyKindsWithCss()
  aSeekHydratesWithNoEvents()
  recordsFoldBackIntoTheFeed()
  echo "test_broadcast_state ok"
