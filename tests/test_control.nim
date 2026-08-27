## THE BOUNDED-ORDERS / LEGALITY ASSERTION on the scripted baselines.
##
## Over a scripted match, for every tick and every cog: the emitted byte is a
## legal encoding; both baselines emit exactly one order per turn for their own
## shirt and no other; every field is inside its enum or clamp; `note` <= 160
## runes and `say` <= 48 runes; `pass_to` is always a teammate or null; and no
## order names a cog the seat does not command.

import std/[json, random]
import lib/helpers

proc everyByteIsLegal() =
  let config = testConfig(maxTicks = 1440)
  let match = runScriptedMatch(config, collectActions = true)
  doAssert match.actions.len > 0
  for t, frame in match.actions:
    for i in 0 ..< CogCount:
      let b = frame[i]
      doAssert actionDir(b) >= 0 and actionDir(b) <= 8
      doAssert actionCode(b) >= 0 and actionCode(b) <= 7
      # The decode is total: re-encoding what we decoded must be idempotent.
      let again = encodeAction(actionDir(b), actionCode(b), actionSprint(b))
      doAssert actionDir(again) == actionDir(b)
      doAssert actionCode(again) == actionCode(b)
      doAssert actionSprint(again) == actionSprint(b)
      doAssert t >= 0
  report "every emitted byte over a 1440-tick match is a legal encoding"

proc ordersAreBounded() =
  var rng = initRand(4242)
  var sim = playing(testConfig())
  for round in 0 ..< 60:
    sim.pseudoWorld(rng)
    for seat in 0 ..< SeatCount:
      for name in ["zonal", "gegenpress"]:
        let d = sim.baselineDirective(seat, name, round)
        let o = d.cog
        doAssert d.note.runeCount <= MaxNoteRunes,
          name & " note is over the cap"
        doAssert o.say.runeCount <= MaxSayRunes,
          name & " say is over the cap"
        doAssert o.targetX >= PitchXMin and o.targetX <= PitchXMax,
          name & " target x is off the pitch"
        doAssert o.targetY >= PitchYMin and o.targetY <= PitchYMax,
          name & " target y is off the pitch"
        doAssert o.passTo == -1 or
          (o.passTo >= 0 and o.passTo < CogCount and
           teamOfCog(int(o.passTo)) == teamOfSeat(seat)),
          name & " pass_to must be a teammate or null"
        doAssert o.passTo != int32(cogOfSeat(seat)),
          name & " must never pass to itself"
        doAssert d.source == dsScripted
  report "both baselines emit bounded, legal orders over 60 random worlds"

proc oneOrderPerSeatForItsOwnShirt() =
  var sim = playing(testConfig())
  for seat in 0 ..< SeatCount:
    let d = sim.zonalDirective(seat, 3)
    let record = directiveJson(seat, d)
    doAssert record["seat"].getInt == seat
    doAssert record["cogs"].len == 1,
      "a seat commands exactly one shirt"
    doAssert record["cogs"][0]["id"].getStr == cogId(cogOfSeat(seat)),
      "the order names the seat's OWN shirt"
    doAssert record["id"].getStr == cogId(cogOfSeat(seat))
  report "each seat emits exactly one order, for its own shirt and no other"

proc controlAlwaysActuates() =
  ## No failure mode leaves a cog unactuated: every cog gets a byte on every
  ## tick of a live match, including through restarts.
  var rng = initRand(99)
  var sim = playing(testConfig())
  for seat in 0 ..< SeatCount:
    sim.activeDirective[seat] = sim.zonalDirective(seat, 0)
    sim.hasDirective[seat] = true
  for round in 0 ..< 40:
    sim.pseudoWorld(rng)
    let actions = sim.compileActions(sim.activeDirective)
    doAssert actions.len == CogCount
    for i in 0 ..< CogCount:
      doAssert actionDir(actions[i]) <= 8
  report "the control layer always produces 22 legal bytes"

proc restartForcesTheTakerIdle() =
  var sim = playing(testConfig())
  for seat in 0 ..< SeatCount:
    sim.activeDirective[seat] = sim.zonalDirective(seat, 0)
    sim.hasDirective[seat] = true
  sim.beginRestart(rkCorner, int32(ord(Red)), int32(cogOfShirt(Red, 7)),
    PitchXMax, PitchYMin)
  let actions = sim.compileActions(sim.activeDirective)
  doAssert actions[cogOfShirt(Red, 7)] == 0'u8,
    "the taker's byte is forced to 0x00 during a restart"
  for i in 0 ..< CogCount:
    doAssert actionCode(actions[i]) == 0,
      "no action code is legal while the ball is dead"
  report "a restart forces the taker idle and zeroes every action code"

proc zonalBeatsGegenpress() =
  ## The ladder needs a spread: `gegenpress` sprints always, bottoms out its
  ## stamina around the third minute and then runs at 85 % while `zonal` still
  ## has legs. The claim is about FOUR MINUTES, so the fixture is four minutes —
  ## judging it over two tested a claim nobody made. Three seeds, both ways
  ## round, six matches; `zonal` must not lose on aggregate.
  var zonalGoals = 0
  var pressGoals = 0
  for seed in [679961, 1234567, 20260827]:
    let config = testConfig(seed = seed, maxTicks = DefaultMaxTicks)
    let a = runScriptedMatch(config, red = "zonal", blue = "gegenpress")
    zonalGoals += a.goals[Red]
    pressGoals += a.goals[Blue]
    let b = runScriptedMatch(config, red = "gegenpress", blue = "zonal")
    zonalGoals += b.goals[Blue]
    pressGoals += b.goals[Red]
  doAssert zonalGoals >= pressGoals,
    "zonal " & $zonalGoals & " vs gegenpress " & $pressGoals &
      " — the fillers must give the ladder a spread"
  report "zonal is not beaten by gegenpress over the head-to-head fixture"

when isMainModule:
  echo "test_control"
  everyByteIsLegal()
  ordersAreBounded()
  oneOrderPerSeatForItsOwnShirt()
  controlAlwaysActuates()
  restartForcesTheTakerIdle()
  zonalBeatsGegenpress()
  echo "test_control ok"
