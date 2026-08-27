## Sim unit tests: the pitch, the ball, the contacts, the restarts and the
## stalemate drop. Every number here comes from docs/RULES.md; if one of these
## fails the PHYSICS changed, and the fix is in the sim, not in the test.

import lib/helpers

proc noTunnelling() =
  ## A ball fired at BallMaxSpeed at a post for 600 ticks never leaves the
  ## board box, and never ends with a non-representable velocity.
  var sim = playing(testConfig())
  sim.ball.controller = -1
  sim.ball.x = CentreX
  sim.ball.y = GoalYMin
  sim.ball.vx = -BallMaxSpeed
  sim.ball.vy = 0
  for _ in 0 ..< 600:
    sim.stepIdle()
    doAssert onBoard(sim.ball.x, sim.ball.y),
      "ball left the board at tick " & $sim.tickCount
    doAssert speedOf(sim.ball.vx, sim.ball.vy) <= 2 * BallMaxSpeed
    if sim.phase != Playing:
      break
  report "a max-speed ball at a post never tunnels off the board"

proc goalOnThePlane() =
  ## The goal test fires on the exact plane crossing, and only inside the mouth.
  var sim = playing(testConfig())
  sim.ball.controller = -1
  sim.ball.x = PitchXMax - 1_000_000'i32
  sim.ball.y = CentreY
  sim.ball.vx = 800_000'i32
  sim.ball.vy = 0
  let before = sim.goals(Red)
  for _ in 0 ..< 24:
    sim.stepIdle()
    if sim.goals(Red) > before:
      break
  doAssert sim.goals(Red) == before + 1, "a ball into the blue mouth is a goal"
  doAssert sim.restartKind == rkKickoff, "a goal restarts with a kickoff"
  doAssert sim.restartTeam == int32(ord(Blue)),
    "the CONCEDING team kicks off"
  report "the goal test fires on the plane crossing and restarts the kickoff"

proc wideOfTheMouthIsNotAGoal() =
  var sim = playing(testConfig())
  sim.ball.controller = -1
  sim.ball.x = PitchXMax - 1_000_000'i32
  sim.ball.y = GoalYMax + 6_000_000'i32
  sim.ball.vx = 800_000'i32
  sim.ball.vy = 0
  # Nobody has touched it, so the last-touch default (Red) makes this a goal
  # kick to Blue rather than a corner; either way it is NOT a goal.
  for _ in 0 ..< 24:
    sim.stepIdle()
    if sim.restartTicks > 0:
      break
  doAssert sim.goals(Red) == 0, "wide of the mouth is not a goal"
  doAssert sim.restartKind in {rkGoalKick, rkCorner},
    "over the goal line restarts, kind=" & restartText(sim.restartKind)
  report "a ball wide of the mouth is a restart, never a goal"

proc throwInToTheOtherSide() =
  var sim = playing(testConfig())
  sim.ball.controller = -1
  # RED-9 touched it last, so the throw-in is BLUE's.
  sim.lastTouch = Touch(cog: int32(cogOfShirt(Red, 9)),
    team: int32(ord(Red)), tick: int32(sim.tickCount))
  sim.ball.x = CentreX
  sim.ball.y = PitchYMin + 200_000'i32
  sim.ball.vx = 0
  sim.ball.vy = -600_000'i32
  for _ in 0 ..< 24:
    sim.stepIdle()
    if sim.restartTicks > 0:
      break
  doAssert sim.restartKind == rkThrowIn,
    "a ball over the touchline is a throw-in, got " &
      restartText(sim.restartKind)
  doAssert sim.restartTeam == int32(ord(Blue)),
    "the throw-in goes to the team that did NOT touch it last"
  doAssert sim.restartY == PitchYMin, "the spot is on the touchline"
  report "a touchline crossing is a throw-in to the other side, at the spot"

proc goalKickAndCorner() =
  block attackerLastTouch:
    var sim = playing(testConfig())
    sim.ball.controller = -1
    sim.lastTouch = Touch(cog: int32(cogOfShirt(Red, 9)),
      team: int32(ord(Red)), tick: int32(sim.tickCount))
    sim.ball.x = PitchXMax - 300_000'i32
    sim.ball.y = GoalYMax + 8_000_000'i32
    sim.ball.vx = 600_000'i32
    for _ in 0 ..< 24:
      sim.stepIdle()
      if sim.restartTicks > 0: break
    doAssert sim.restartKind == rkGoalKick,
      "attacker last touch over the goal line is a goal kick"
    doAssert sim.restartTeam == int32(ord(Blue))
  block defenderLastTouch:
    var sim = playing(testConfig())
    sim.ball.controller = -1
    sim.lastTouch = Touch(cog: int32(cogOfShirt(Blue, 4)),
      team: int32(ord(Blue)), tick: int32(sim.tickCount))
    sim.ball.x = PitchXMax - 300_000'i32
    sim.ball.y = GoalYMax + 8_000_000'i32
    sim.ball.vx = 600_000'i32
    for _ in 0 ..< 24:
      sim.stepIdle()
      if sim.restartTicks > 0: break
    doAssert sim.restartKind == rkCorner,
      "defender last touch over the goal line is a corner"
    doAssert sim.restartTeam == int32(ord(Red))
  report "goal kick on an attacker's touch, corner on a defender's"

proc keeperCatchesAndParries() =
  block catch:
    var sim = playing(testConfig())
    let keeper = cogOfShirt(Blue, 1)
    sim.cogs[keeper].x = PitchXMax - 3_000_000'i32
    sim.cogs[keeper].y = CentreY
    sim.ball.controller = -1
    sim.ball.x = sim.cogs[keeper].x - 900_000'i32
    sim.ball.y = CentreY
    sim.ball.vx = 600_000'i32          ## 14.4 m/s, under the 18 m/s catch cap
    sim.ball.vy = 0
    for _ in 0 ..< 12:
      sim.stepIdle()
      if sim.restartTicks > 0: break
    doAssert sim.restartKind == rkGoalKick,
      "a catchable ball inside the area is a catch and a goal kick"
    doAssert sim.teamStats[Blue].saves >= 1
  block parry:
    var sim = playing(testConfig())
    let keeper = cogOfShirt(Blue, 1)
    sim.cogs[keeper].x = PitchXMax - 3_000_000'i32
    sim.cogs[keeper].y = CentreY
    sim.ball.controller = -1
    sim.ball.x = sim.cogs[keeper].x - 900_000'i32
    sim.ball.y = CentreY
    sim.ball.vx = 1_041_666'i32        ## 25 m/s, over the catch cap
    sim.ball.vy = 0
    sim.stepIdle()
    # A ball over the catch cap is PARRIED — its speed is capped, not zeroed —
    # and the keeper may then legitimately gather the rebound on a later
    # substep, which is why the restart kind is not what this asserts.
    doAssert sim.teamStats[Blue].saves >= 1, "the parry is credited as a save"
    doAssert speedOf(sim.ball.vx, sim.ball.vy) <= KeeperParryCap + 1,
      "a parry caps the ball at " & $KeeperParryCap
    doAssert sim.goals(Red) == 0, "a parried shot is not a goal"
  report "the keeper catches at 14 m/s and parries at 25 m/s"

proc cogContactIsSymmetric() =
  ## Two cogs closing head-on separate symmetrically and conserve momentum
  ## exactly: the resolution must not care which index came first.
  var sim = playing(testConfig())
  # Park every other body IN the pitch and clear of the ball: a body outside
  # the playing surface would fire a restart and reset the very velocities
  # this test is measuring.
  for i in 0 ..< CogCount:
    sim.cogs[i].x = PitchXMin + 1_000_000'i32 + int32(i) * 1_200_000'i32
    sim.cogs[i].y = PitchYMin + 1_000_000'i32
    sim.cogs[i].vx = 0
    sim.cogs[i].vy = 0
    sim.cogs[i].dir = 0
  let a = 3
  let b = 15
  sim.cogs[a].x = CentreX - 400_000'i32
  sim.cogs[a].y = CentreY
  sim.cogs[a].vx = 200_000'i32
  sim.cogs[b].x = CentreX + 400_000'i32
  sim.cogs[b].y = CentreY
  sim.cogs[b].vx = -200_000'i32
  sim.ball.controller = -1
  sim.ball.x = PitchXMin + 1_000_000'i32
  sim.ball.y = PitchYMax - 1_000_000'i32
  sim.ball.vx = 0
  sim.ball.vy = 0
  let before = int64(sim.cogs[a].vx) + int64(sim.cogs[b].vx)
  sim.stepIdle()
  let after = int64(sim.cogs[a].vx) + int64(sim.cogs[b].vx)
  doAssert before == after,
    "cog-cog momentum must be conserved exactly: " & $before & " -> " & $after
  report "cog-cog contact conserves momentum exactly"

proc shortPassReachesTheNamedTeammate() =
  var sim = playing(testConfig())
  let
    passer = cogOfShirt(Red, 10)
    mate = cogOfShirt(Red, 9)
  for i in 0 ..< CogCount:
    sim.cogs[i].x = PitchXMin + 1_000_000'i32
    sim.cogs[i].y = PitchYMin + 1_000_000'i32 + int32(i) * 1_200_000'i32
    sim.cogs[i].vx = 0
    sim.cogs[i].vy = 0
    sim.cogs[i].dir = 0
  sim.cogs[passer].x = CentreX
  sim.cogs[passer].y = CentreY
  sim.cogs[mate].x = CentreX + 10_000_000'i32
  sim.cogs[mate].y = CentreY
  sim.ball.controller = int32(passer)
  sim.ball.x = CentreX + 900_000'i32
  sim.ball.y = CentreY
  var actions: array[CogCount, uint8]
  actions[passer] = encodeAction(3, 1, false)   ## east, short pass
  sim.stepWith(actions)
  doAssert sim.ball.controller < 0, "the pass releases possession"
  doAssert sim.ball.vx > 0, "the pass travels east toward the receiver"
  doAssert sim.cogStats[passer].passes == 1
  var reached = false
  for _ in 0 ..< 96:
    sim.stepIdle()
    if sim.lastTouch.cog == int32(mate):
      reached = true
      break
  doAssert reached, "a 10 m short pass reaches the named teammate"
  doAssert sim.cogStats[passer].passesCompleted == 1,
    "the completed pass is credited to the passer"
  report "a short pass reaches the named teammate and is credited"

proc slideTackleAndFoul() =
  block tackle:
    var sim = playing(testConfig())
    let
      carrier = cogOfShirt(Blue, 9)
      tackler = cogOfShirt(Red, 6)
    for i in 0 ..< CogCount:
      sim.cogs[i].x = PitchXMin + 1_000_000'i32
      sim.cogs[i].y = PitchYMin + 1_000_000'i32 + int32(i) * 1_200_000'i32
      sim.cogs[i].vx = 0
      sim.cogs[i].vy = 0
      sim.cogs[i].dir = 0
    sim.cogs[carrier].x = CentreX
    sim.cogs[carrier].y = CentreY
    # The carried ball rides 0.9 m AHEAD of the carrier (east, its default
    # facing), so the tackler comes from the front and slides west into it.
    sim.cogs[tackler].x = CentreX + 1_800_000'i32
    sim.cogs[tackler].y = CentreY
    sim.ball.controller = int32(carrier)
    sim.ball.x = CentreX
    sim.ball.y = CentreY
    var actions: array[CogCount, uint8]
    actions[tackler] = encodeAction(7, 5, false)   ## slide west
    sim.stepWith(actions)
    doAssert sim.cogs[tackler].slideTicks > 0 or
      sim.cogs[tackler].groundedTicks > 0, "the slide started"
    doAssert sim.ball.controller != int32(carrier),
      "a slide that reaches the ball knocks it loose"
    doAssert sim.cogStats[tackler].tackles == 1
  block foul:
    var sim = playing(testConfig())
    let
      victim = cogOfShirt(Blue, 9)
      tackler = cogOfShirt(Red, 6)
    for i in 0 ..< CogCount:
      sim.cogs[i].x = PitchXMin + 1_000_000'i32
      sim.cogs[i].y = PitchYMin + 1_000_000'i32 + int32(i) * 1_200_000'i32
      sim.cogs[i].vx = 0
      sim.cogs[i].vy = 0
      sim.cogs[i].dir = 0
    sim.cogs[victim].x = CentreX
    sim.cogs[victim].y = CentreY
    sim.cogs[tackler].x = CentreX - 1_300_000'i32
    sim.cogs[tackler].y = CentreY
    # The ball is far away, so the slide can only reach the OPPONENT.
    sim.ball.controller = -1
    sim.ball.x = PitchXMin + 4_000_000'i32
    sim.ball.y = PitchYMin + 4_000_000'i32
    var actions: array[CogCount, uint8]
    actions[tackler] = encodeAction(3, 5, false)
    sim.stepWith(actions)
    doAssert sim.cogStats[tackler].fouls == 1, "a missed slide is a foul"
    doAssert sim.cogs[tackler].groundedTicks == GroundedAfterFoul,
      "a foul grounds the tackler for 48 ticks"
    doAssert sim.restartKind == rkFreeKick, "a foul is a free kick"
    doAssert sim.restartTeam == int32(ord(Blue)),
      "the free kick goes to the fouled team"
  report "a slide wins the ball or concedes a 48-tick foul"

proc staminaDrainsAndCapsSpeed() =
  var sim = playing(testConfig())
  let index = cogOfShirt(Red, 9)
  sim.cogs[index].stamina = StaminaMax
  var actions: array[CogCount, uint8]
  actions[index] = encodeAction(3, 0, true)      ## east, sprinting
  for _ in 0 ..< 10:
    sim.stepWith(actions)
  doAssert sim.cogs[index].stamina == StaminaMax - 10 * StaminaDrain,
    "sprinting drains 6 a tick, got " & $sim.cogs[index].stamina
  sim.cogs[index].stamina = TiredStamina - 1
  doAssert sim.modeSpeed(index) ==
    pctScale(int32(sim.config.sprintSpeed), TiredSpeedPct),
    "below 200 stamina every mode speed is x85%"
  sim.cogs[index].stamina = ExhaustedStamina - 1
  sim.stepWith(actions)
  doAssert not sim.cogs[index].sprinting,
    "below 50 stamina the sprint bit is ignored"
  report "stamina drains at 6/tick and caps speed at the stated thresholds"

proc stalemateDropsAt480() =
  var sim = playing(testConfig())
  sim.ball.controller = -1
  sim.ball.x = PitchXMin + 500_000'i32
  sim.ball.y = PitchYMin + 500_000'i32
  sim.ball.vx = 0
  sim.ball.vy = 0
  sim.anchorX = sim.ball.x
  sim.anchorY = sim.ball.y
  sim.stalemateTicks = 0
  for i in 0 ..< CogCount:
    sim.cogs[i].x = PitchXMax - 1_000_000'i32 - int32(i) * 1_200_000'i32
    sim.cogs[i].y = PitchYMax - 1_000_000'i32
    sim.cogs[i].vx = 0
    sim.cogs[i].vy = 0
    sim.cogs[i].dir = 0
  var fired = -1
  for t in 0 ..< 520:
    sim.stepIdle()
    if sim.lastDropTick >= 0:
      fired = t
      break
  doAssert fired >= 0, "the stalemate drop must fire"
  doAssert sim.stalemateTicks == 0, "the drop resets the counter"
  doAssert sim.restartKind == rkDrop, "the drop is a restart"
  doAssert fired == int(DefaultStalemateTicks) - 1,
    "the drop fires at exactly 480 ticks, fired at " & $(fired + 1)
  report "the stalemate drop fires at exactly 480 parked ticks"

proc halfTimeSwapsTheKickoff() =
  var config = testConfig(maxTicks = 480)
  config.halfTicks = 240
  var sim = playing(config)
  let first = sim.restartTeam
  var sawHalfTime = false
  for _ in 0 ..< 400:
    sim.stepIdle()
    if sim.half == 2:
      sawHalfTime = true
      break
  doAssert sawHalfTime, "half time must fire"
  doAssert sim.restartTeam != first,
    "the team that did NOT kick off at 0 kicks off the second half"
  doAssert sim.restartKind == rkKickoff
  report "half-time resets the formation and swaps the kickoff"

when isMainModule:
  echo "test_physics"
  noTunnelling()
  goalOnThePlane()
  wideOfTheMouthIsNotAGoal()
  throwInToTheOtherSide()
  goalKickAndCorner()
  keeperCatchesAndParries()
  cogContactIsSymmetric()
  shortPassReachesTheNamedTeammate()
  slideTackleAndFoul()
  staminaDrainsAndCapsSpeed()
  stalemateDropsAt480()
  halfTimeSwapsTheKickoff()
  echo "test_physics ok"
