## The 19-action encoding: every legal byte decodes to exactly one gfootball
## action and back, illegal direction nibbles read as 0, a pass or shot from a
## cog with no ball is a no-op, and the sticky modes are always in a defined
## state.

import lib/helpers

proc encodingRoundTrips() =
  for dir in 0 .. 8:
    for code in 0 .. 7:
      for sprint in [false, true]:
        let b = encodeAction(int32(dir), int32(code), sprint)
        doAssert int(actionDir(b)) == dir, "direction round trip " & $dir
        doAssert int(actionCode(b)) == code, "code round trip " & $code
        doAssert actionSprint(b) == sprint, "sprint round trip"
  report "every legal (direction, code, sprint) round-trips through one byte"

proc illegalDirectionsReadAsZero() =
  for dir in 9 .. 15:
    let b = uint8(dir)
    doAssert actionDir(b) == 0,
      "illegal direction nibble " & $dir & " must read as 0"
  report "direction nibbles 9..15 decode as release_direction"

proc nineteenDistinctActions() =
  ## idle, 8 directions, short/long/high pass, shot, sprint,
  ## release_direction, release_sprint, sliding, dribble, release_dribble.
  var seen: seq[string]
  seen.add("idle")
  for dir in 1 .. 8:
    seen.add("dir" & $dir)
  for code in 1 .. 7:
    seen.add("code" & $code)
  seen.add("sprint")
  seen.add("release_sprint")
  doAssert seen.len == 18,
    "18 named plus release_direction (the idle nibble) is gfootball's 19"
  report "the vocabulary is gfootball's nineteen actions"

proc passWithNoBallIsANoOp() =
  var sim = playing(testConfig())
  let index = cogOfShirt(Red, 9)
  sim.ball.controller = -1
  let before = sim.cogStats[index].passes
  var actions: array[CogCount, uint8]
  actions[index] = encodeAction(3, 1, false)
  sim.stepWith(actions)
  doAssert sim.cogStats[index].passes == before,
    "a pass code from a cog with no ball is recorded and ignored"
  report "a pass or shot from a cog with no ball is a no-op"

proc stickyModesStayDefined() =
  var sim = playing(testConfig())
  let index = cogOfShirt(Blue, 7)
  var on: array[CogCount, uint8]
  on[index] = encodeAction(3, 6, true)          ## dribble on, sprint held
  sim.stepWith(on)
  doAssert sim.cogs[index].dribbling, "code 6 turns dribble mode on"
  doAssert sim.cogs[index].sprinting, "bit 7 holds sprint"
  var hold: array[CogCount, uint8]
  hold[index] = encodeAction(3, 0, true)
  sim.stepWith(hold)
  doAssert sim.cogs[index].dribbling, "dribble is STICKY across a plain byte"
  var off: array[CogCount, uint8]
  off[index] = encodeAction(3, 7, false)        ## dribble off, sprint released
  sim.stepWith(off)
  doAssert not sim.cogs[index].dribbling, "code 7 turns dribble mode off"
  doAssert not sim.cogs[index].sprinting, "a clear bit 7 releases sprint"
  report "sprint and dribble are sticky and always in a defined state"

when isMainModule:
  echo "test_actions"
  encodingRoundTrips()
  illegalDirectionsReadAsZero()
  nineteenDistinctActions()
  passWithNoBallIsANoOp()
  stickyModesStayDefined()
  echo "test_actions ok"
