## The two scripted baselines. Both emit the SAME order object an LLM does, on
## the same 10 s cadence, so their output is legal by construction and directly
## comparable — which is what makes the bounded-orders test in
## tests/test_control.nim meaningful. Both are pure functions of world state.
##
## `zonal` is load-bearing in four places: it is the certification player, the
## per-turn fallback when a seat's LLM call fails twice, the driver of a seat
## that never connects, and the default for a seat that registers with neither
## PLAYER_PROMPT nor PLAYER_SCRIPTED.
##
## `gegenpress` is the second filler: deliberately different in shape and
## weaker over 4:00, because its `sprint: always` bottoms out its stamina
## around the third minute and its cogs then run at 85 % while `zonal` still
## has legs. The ladder needs a spread.

import
  std/strutils,
  sim, builtin_ai, directives

type
  Baseline* = enum
    blZonal = "zonal"
    blGegenpress = "gegenpress"

proc baselineOfName*(name: string): Baseline =
  if name.strip().toLowerAscii() == "gegenpress": blGegenpress else: blZonal

proc ballInOwnHalf*(sim: SimServer, team: Team): bool {.inline.} =
  if attackDir(team) > 0: sim.ball.x < CentreX else: sim.ball.x > CentreX

proc ballPastHalfway*(sim: SimServer, team: Team): bool {.inline.} =
  not sim.ballInOwnHalf(team)

proc onBallFor(sim: SimServer, index: int, shootRange,
    pressureRadius: int32): OnBall =
  let
    team = teamOfCog(index)
    gx = targetGoalX(team)
    goalDist = distI(gx - sim.cogs[index].x, CentreY - sim.cogs[index].y)
  if goalDist <= shootRange:
    return obShoot
  if sim.nearestOpponentDist(index) < pressureRadius:
    return obPassShort
  obDribble

type
  ZonalParams* = object
    ## `zonal`'s three free parameters. They are NOT guessed: the grid harness
    ## `tools/tune_baselines.nim` sweeps them and `docs/tuning/baseline-grid.md`
    ## is the committed sweep, with the train and holdout tables and the winner.
    ## Re-run the harness after any physics change; the numbers below are only
    ## as good as the sim they were measured on.
    pressRadius*: int32      ## press when the opponent has the ball this near
    shootRange*: int32       ## `on_ball = shoot` inside this range of the goal
    pressureRadius*: int32   ## an opponent this near forces `pass_short`

const
  ZonalTuned* = ZonalParams(
    pressRadius: 12_000_000'i32,
    shootRange: 16_000_000'i32,
    pressureRadius: 1_500_000'i32)
    ## The harness's winner over 60 grid points and 240 full-length matches:
    ## train goal difference +5 against `gegenpress` and +8 on the holdout
    ## seeds, against -1 / +2 for the guessed 15/20/2.5 point the design note
    ## names. See docs/tuning/baseline-grid.md for the method and the table.

proc zonalDirectiveWith*(sim: SimServer, seat: int, turn: int,
    params: ZonalParams): Directive =
  ## The reference shape: hold the zone, support the ball, press when it is
  ## near and in the other side's possession, and go and win a loose ball.
  ## Parameterised so the grid harness can sweep it; `zonalDirective` below is
  ## this proc at the tuned point, and is what the game runs.
  result = emptyDirective(seat)
  result.turn = int32(turn)
  result.half = sim.half
  result.source = dsScripted
  result.note = "hold the zone, support the ball, press when it is close"
  let
    index = cogOfSeat(seat)
    team = teamOfSeat(seat)
    anchor = sim.translatedAnchor(index)
    possession = sim.teamInPossession()
    mine = int32(ord(team))
  var order = result.cog
  order.role = SeatRole[seat]
  order.targetX = anchor.x
  order.targetY = anchor.y
  order.sprint = spAuto
  order.tackle = tkAuto
  order.passTo = -1
  if sim.ballIsLoose():
    order.intent = inCarry
    order.say = "mine"
  elif possession == mine:
    if order.role == roleStriker and sim.ballPastHalfway(team):
      order.intent = inMakeRun
      order.say = "in behind"
    else:
      order.intent = inSupport
      order.say = "square on"
  elif sim.distToBall(index) <= params.pressRadius:
    order.intent = inPress
    order.say = "closing"
  else:
    order.intent = inHoldShape
    order.say = "holding"
  order.onBall = sim.onBallFor(index, params.shootRange,
    params.pressureRadius)
  result.cog = order

proc zonalDirective*(sim: SimServer, seat: int, turn: int): Directive =
  ## `zonal` at the tuned point.
  sim.zonalDirectiveWith(seat, turn, ZonalTuned)

proc gegenpressDirective*(sim: SimServer, seat: int, turn: int): Directive =
  ## Chase everything, everywhere. Loses to `zonal` over four minutes, which is
  ## the point.
  result = emptyDirective(seat)
  result.turn = int32(turn)
  result.half = sim.half
  result.source = dsScripted
  result.note = "hunt the ball high, everyone forward"
  let
    index = cogOfSeat(seat)
    team = teamOfSeat(seat)
    dir = attackDir(team)
    possession = sim.teamInPossession()
    mine = int32(ord(team))
  var order = result.cog
  order.role = SeatRole[seat]
  order.targetX = clamp(sim.ball.x + 6_000_000'i32 * dir,
    PitchXMin, PitchXMax)
  order.targetY = clamp(sim.ball.y, PitchYMin, PitchYMax)
  order.sprint = spAlways
  order.tackle = tkAuto
  order.passTo = -1
  if inPenaltyArea(team, sim.cogs[index].x, sim.cogs[index].y):
    order.intent = inShadow
    order.say = "picking him up"
  elif possession == mine:
    order.intent = inMakeRun
    order.say = "go go go"
  else:
    order.intent = inPress
    order.say = "hunt it"
  order.onBall = sim.onBallFor(index, 26_000_000'i32, 2_500_000'i32)
  result.cog = order

proc baselineDirective*(
  sim: SimServer,
  seat: int,
  name: string,
  turn: int
): Directive =
  case baselineOfName(name)
  of blGegenpress: sim.gegenpressDirective(seat, turn)
  of blZonal: sim.zonalDirective(seat, turn)
