## The scoring formula and its sign, the reachable end conditions, and the
## zero-sum property the ladder needs.

import std/json
import lib/helpers

proc scoredSim(redGoals, blueGoals: int, reason = reasonComplete,
    rule = erFullTime): SimServer =
  result = seatedSim(testConfig())
  result.teamStats[Red].goals = int32(redGoals)
  result.teamStats[Blue].goals = int32(blueGoals)
  result.endReason = reason
  result.endRule = rule

proc formulaAndSign() =
  const cases = [
    (0, 0, 500), (1, 0, 667), (2, 0, 833), (3, 0, 1000),
    (5, 0, 1000), (0, 2, 167), (0, 1, 333), (2, 3, 333)
  ]
  for (red, blue, wantRed) in cases:
    let sim = scoredSim(red, blue)
    doAssert sim.scorePermille(0) == wantRed,
      $red & "-" & $blue & " should score " & $wantRed & " for red, got " &
        $sim.scorePermille(0)
    doAssert sim.scorePermille(1) == 1000 - wantRed,
      "the two team scores must sum to exactly 1.000"
  report "the score formula and its sign are right at every margin"

proc eightScoresSumToFour() =
  for red in 0 .. 6:
    for blue in 0 .. 6:
      let sim = scoredSim(red, blue)
      var total = 0
      for seat in 0 ..< SeatCount:
        total += sim.scorePermille(seat)
      doAssert total == 4000,
        "the eight scores must sum to 4.000 at " & $red & "-" & $blue &
          ", got " & $total
  report "the eight seat scores always sum to exactly 4.000"

proc winFollowsGoalDifference() =
  let a = scoredSim(2, 1)
  for seat in 0 ..< SeatCount:
    doAssert a.seatWon(seat) == (teamOfSeat(seat) == Red)
  let draw = scoredSim(1, 1)
  for seat in 0 ..< SeatCount:
    doAssert not draw.seatWon(seat), "a draw wins for nobody"
  report "win follows goal difference and a draw wins for nobody"

proc faultScoresHalfForEveryone() =
  let sim = scoredSim(4, 0, reasonFault, erSimFault)
  for seat in 0 ..< SeatCount:
    doAssert sim.scorePermille(seat) == 500,
      "a fault episode scores 0.500 for every seat"
    doAssert not sim.seatWon(seat), "a fault wins for nobody"
  report "a fault scores 0.500 x 8 with win all false"

proc resultsDocumentShape() =
  let sim = scoredSim(2, 1)
  let doc = parseJson(sim.playerResultsJson())
  for key in ["names", "scores", "win", "team", "shirt", "goals", "assists",
      "passes", "passesCompleted", "shots", "tackles", "fouls", "llmTurns",
      "fallbackTurns"]:
    doAssert doc.hasKey(key), "results is missing " & key
    doAssert doc[key].len == SeatCount,
      key & " must have one entry per seat, got " & $doc[key].len
  for key in ["teamGoals", "teamShots", "teamShotsOnTarget",
      "teamPossessionTicks"]:
    doAssert doc[key].len == 2, key & " is a [red, blue] pair"
  doAssert doc["reason"].getStr == "complete"
  doAssert doc["endRule"].getStr == "full_time"
  var total = 0.0
  for v in doc["scores"]:
    total += v.getFloat
  doAssert total > 3.999 and total < 4.001, "scores sum to 4.000"
  report "the results document carries every declared key at the right arity"

proc endConditionsAreReachable() =
  block fullTime:
    let match = runScriptedMatch(testConfig(maxTicks = 480))
    doAssert match.reason == reasonComplete and match.rule == erFullTime,
      "a played-out match ends complete/full_time"
  block mercy:
    var config = testConfig(maxTicks = 480)
    config.halfTicks = 480          ## no half-time in the way of the boundary
    var sim = playing(config)
    sim.teamStats[Red].goals = 6
    sim.stepIdle(int(sim.config.turnTicks) + 2)
    doAssert sim.endRule == erMercy and sim.endReason == reasonComplete,
      "a five-goal lead at a turn boundary is complete/mercy"
  block wallClock:
    var sim = playing(testConfig())
    sim.wallClockStop()
    doAssert sim.endReason == reasonDeadline and sim.endRule == erWallClock
  block hostError:
    var sim = playing(testConfig())
    sim.hostErrorStop()
    doAssert sim.endReason == reasonFault and sim.endRule == erHostError
  block simFault:
    var sim = playing(testConfig())
    sim.ball.z = 200_000_000'i32     ## a ball with no defined phase
    sim.stepIdle()
    doAssert sim.endReason == reasonFault and sim.endRule == erSimFault,
      "a tripped invariant guard is fault/sim_fault"
  report "every declared reason/endRule pair is reachable, and no other"

proc endingIsIdempotent() =
  var sim = playing(testConfig())
  sim.finishGame(reasonComplete, erFullTime)
  sim.finishGame(reasonFault, erHostError)
  doAssert sim.endReason == reasonComplete and sim.endRule == erFullTime,
    "the FIRST ending wins; a later stop cannot overwrite the verdict"
  report "the first ending wins"

when isMainModule:
  echo "test_scoring"
  formulaAndSign()
  eightScoresSumToFour()
  winFollowsGoalDifference()
  faultScoresHalfForEveryone()
  resultsDocumentShape()
  endConditionsAreReachable()
  endingIsIdempotent()
  echo "test_scoring ok"
