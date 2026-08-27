## THE BOUNDED-ORDERS / LEGALITY ASSERTION on the scripted baselines.
##
## Over a scripted match, for every tick and every cog: the emitted byte is a
## legal encoding; both baselines emit exactly one order per turn for their own
## shirt and no other; every field is inside its enum or clamp; `note` <= 160
## runes and `say` <= 48 runes; `pass_to` is always a teammate or null; and no
## order names a cog the seat does not command.
##
## `aFullScriptedEpisodeIsCompleteAndLegal` is the checklist's item 7 in one
## test: ONE all-scripted episode played to the natural end, asserting both
## `results.reason == "complete"` and the legality of every byte and every order
## it emitted on the way there.

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

proc chasingKeepsItsDirectionBits() =
  ## The control layer's rule 2 (design.md:537-538): the direction nibble is 0
  ## when the cog has arrived AND IS NOT CHASING THE BALL. A cog that is the
  ## closest of its team to a loose ball is chasing, and its steering point is
  ## the interception point — which sits nearly on top of a slow ball — so
  ## dropping the nibble there parks the cog beside the ball it was sent to win.
  var sim = playing(testConfig())
  let
    seat = 0
    index = cogOfSeat(seat)
  # Every other cog is parked in the far corner, so `index` is unambiguously
  # its team's nearest to the ball.
  for i in 0 ..< CogCount:
    sim.cogs[i].x = PitchXMax - 1_000_000'i32
    sim.cogs[i].y = PitchYMax - 1_000_000'i32
    sim.cogs[i].vx = 0
    sim.cogs[i].vy = 0
    sim.cogs[i].dir = 0
  sim.ball.controller = -1
  sim.ball.dead = false
  sim.ball.x = CentreX
  sim.ball.y = CentreY
  sim.ball.vx = 60_000'i32          ## crawling east, so the intercept point is
  sim.ball.vy = 0                   ## within ArriveUm of the cog
  sim.cogs[index].x = CentreX - 200_000'i32
  sim.cogs[index].y = CentreY
  doAssert sim.ballIsLoose()
  doAssert sim.nearestOfTeamToBall(teamOfSeat(seat)) == index
  let p = sim.interceptPoint(index)
  doAssert distI(p.x - sim.cogs[index].x, p.y - sim.cogs[index].y) < ArriveUm,
    "the fixture must put the intercept point inside the arrival radius"
  for seatIndex in 0 ..< SeatCount:
    sim.activeDirective[seatIndex] = sim.zonalDirective(seatIndex, 0)
    sim.hasDirective[seatIndex] = true
  let actions = sim.compileActions(sim.activeDirective)
  doAssert actionDir(actions[index]) != 0,
    "a chasing cog keeps its direction bits, got dir 0"
  report "an arrived cog that is still chasing keeps its direction bits"

proc theKeeperPlaysAGoalKick() =
  ## Design note §The built-in AI item 1: "on possession, goal-kick `pass_long`
  ## to the most open teammate beyond the halfway line, else `pass_short` to the
  ## nearest full back". The keeper used to run the outfield safe option, which
  ## carries the ball toward the far goal.
  proc parked(): SimServer =
    result = playing(testConfig())
    for i in 0 ..< CogCount:
      result.cogs[i].x = PitchXMin + 8_000_000'i32
      result.cogs[i].y = PitchYMin + 2_000_000'i32 + int32(i) * 2_000_000'i32
      result.cogs[i].vx = 0
      result.cogs[i].vy = 0
      result.cogs[i].dir = 0
  let keeper = cogOfShirt(Red, 1)

  block longBall:
    var sim = parked()
    let target = cogOfShirt(Red, 9)
    sim.cogs[keeper].x = PitchXMin + 3_000_000'i32
    sim.cogs[keeper].y = CentreY
    sim.cogs[target].x = CentreX + 2_000_000'i32   ## just beyond halfway
    sim.cogs[target].y = CentreY
    sim.ball.controller = int32(keeper)
    sim.ball.x = sim.cogs[keeper].x
    sim.ball.y = sim.cogs[keeper].y
    sim.ball.dead = false
    doAssert sim.mostOpenBeyondHalfway(keeper) == target
    let b = sim.builtinAction(keeper)
    doAssert actionCode(b) == 2,
      "a keeper on the ball plays a long goal kick, got code " &
        $actionCode(b)
    doAssert actionDir(b) == 3, "the goal kick points east, at the target"

  block shortToTheFullBack:
    var sim = parked()
    ## Nobody past halfway: the short option to the nearer full back.
    sim.cogs[keeper].x = PitchXMin + 3_000_000'i32
    sim.cogs[keeper].y = CentreY
    sim.ball.controller = int32(keeper)
    sim.ball.x = sim.cogs[keeper].x
    sim.ball.y = sim.cogs[keeper].y
    sim.ball.dead = false
    doAssert sim.mostOpenBeyondHalfway(keeper) == -1
    let back = sim.nearestFullBack(keeper)
    doAssert back == cogOfShirt(Red, 2) or back == cogOfShirt(Red, 3)
    let b = sim.builtinAction(keeper)
    doAssert actionCode(b) == 1,
      "with nothing on beyond halfway the keeper plays short, got code " &
        $actionCode(b)
  report "the built-in keeper on the ball plays a goal kick, never a carry"

proc aFullScriptedEpisodeIsCompleteAndLegal() =
  ## Acceptance checklist item 7, in ONE test: an all-scripted episode played to
  ## its NATURAL END, asserting both halves together. Split across two tests at
  ## two match lengths (the review's F15), neither half witnessed the other: a
  ## baseline can play legally for 480 ticks and stall at 3000, or reach full
  ## time while emitting an order nobody checked.
  let config = testConfig(maxTicks = DefaultMaxTicks)
  let match = runScriptedMatch(config, collectActions = true)

  # (a) the episode reached its own end, on the clock.
  let results = parseJson(match.resultsJson)
  doAssert results["reason"].getStr == "complete",
    "an all-scripted episode must end complete, got " &
      results["reason"].getStr
  doAssert results["endRule"].getStr == "full_time",
    "and on the full-time whistle, got " & results["endRule"].getStr
  doAssert match.reason == reasonComplete and match.rule == erFullTime
  doAssert match.ticks >= config.maxTicks,
    "full time means the whole clock was played, got " & $match.ticks
  doAssert results["scores"].len == SeatCount

  # (b) every action byte of every tick, from the same episode.
  doAssert match.actions.len >= config.maxTicks,
    "one frame of bytes per tick, got " & $match.actions.len
  for t, frame in match.actions:
    for i in 0 ..< CogCount:
      let b = frame[i]
      doAssert actionDir(b) >= 0 and actionDir(b) <= 8,
        "illegal direction nibble at tick " & $t & " cog " & $i
      doAssert actionCode(b) >= 0 and actionCode(b) <= 7,
        "illegal action code at tick " & $t & " cog " & $i
      let again = encodeAction(actionDir(b), actionCode(b), actionSprint(b))
      doAssert again == b,
        "the byte at tick " & $t & " cog " & $i & " does not round-trip"

  # (c) every ORDER the baseline issued over the same episode.
  doAssert match.orders.len >= SeatCount,
    "the episode installed no orders"
  for (seat, d) in match.orders:
    let o = d.cog
    doAssert d.source == dsScripted
    doAssert d.note.runeCount <= MaxNoteRunes, "note over the cap"
    doAssert o.say.runeCount <= MaxSayRunes, "say over the cap"
    doAssert o.targetX >= PitchXMin and o.targetX <= PitchXMax,
      "target x off the pitch"
    doAssert o.targetY >= PitchYMin and o.targetY <= PitchYMax,
      "target y off the pitch"
    doAssert o.passTo == -1 or
      (o.passTo >= 0 and o.passTo < CogCount and
       teamOfCog(int(o.passTo)) == teamOfSeat(seat)),
      "pass_to must be a teammate or null"
    doAssert o.passTo != int32(cogOfSeat(seat)),
      "an order must never pass to itself"
    doAssert o.role == SeatRole[seat]
  report "a full all-scripted episode ends complete with every order legal"

when isMainModule:
  echo "test_control"
  everyByteIsLegal()
  ordersAreBounded()
  oneOrderPerSeatForItsOwnShirt()
  controlAlwaysActuates()
  restartForcesTheTakerIdle()
  chasingKeepsItsDirectionBits()
  theKeeperPlaysAGoalKick()
  zonalBeatsGegenpress()
  aFullScriptedEpisodeIsCompleteAndLegal()
  echo "test_control ok"
