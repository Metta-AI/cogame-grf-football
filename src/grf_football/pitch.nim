## The pitch: one fixed 1200 x 800 board carrying an 84 m x 54 m playing
## surface with a 3 m surround. Geometry constants, the out-of-play tests, the
## goal test, the restart spots and the neutral-drop spots — all in integer
## micrometres, all pure functions.
##
## ctf generates, validates, mirrors and pools its terrain; grf-football has
## exactly one board, so `arena.nim`, `map_art.nim`, `map_pool.nim`,
## `mapgen_styles.nim` and the whole editor/mapkit tree are DELETED rather than
## ported. The turf BAKE lives in `global.nim` with the rest of the rendering:
## this module is inside the float-free grep guard
## (tests/test_determinism.nim) and pixie is a float API.

import sim_types

const
  Posts*: array[4, tuple[x, y: int32]] = [
    (PitchXMin, GoalYMin),
    (PitchXMin, GoalYMax),
    (PitchXMax, GoalYMin),
    (PitchXMax, GoalYMax)
  ]
    ## The four goalposts, static circles of PostRadius at the mouth corners.

proc inGoalBand*(y: int32): bool {.inline.} =
  ## True when a y lies in the goal-mouth corridor.
  y >= GoalYMin and y <= GoalYMax

proc inPitch*(x, y: int32): bool {.inline.} =
  ## True when the BALL is in play: on the playing surface. Crossing an edge
  ## is out; crossing a goal line inside the mouth is a goal, tested first.
  x >= PitchXMin and x <= PitchXMax and y >= PitchYMin and y <= PitchYMax

proc onBoard*(x, y: int32): bool {.inline.} =
  ## True when a POINT is inside the board box, including the goal netting.
  ## The physics guard (`sim_fault`) uses this on every body every tick.
  if x >= BoardXMin and x <= BoardXMax and y >= BoardYMin and y <= BoardYMax:
    return true
  false

proc clampToPitch*(x, y: int32): tuple[x, y: int32] {.inline.} =
  (clamp(x, PitchXMin, PitchXMax), clamp(y, PitchYMin, PitchYMax))

proc inPenaltyArea*(team: Team, x, y: int32): bool {.inline.} =
  ## The team's OWN penalty area: 16 m deep, 40 m wide.
  let dy = if y >= CentreY: y - CentreY else: CentreY - y
  if dy > PenaltyHalfH:
    return false
  if team == Red:
    x <= PitchXMin + PenaltyDepth
  else:
    x >= PitchXMax - PenaltyDepth

proc inSixYardBox*(team: Team, x, y: int32): bool {.inline.} =
  let dy = if y >= CentreY: y - CentreY else: CentreY - y
  if dy > SixYardHalfH:
    return false
  if team == Red:
    x <= PitchXMin + SixYardDepth
  else:
    x >= PitchXMax - SixYardDepth

proc goalScoredBy*(ballX, ballY: int32): int32 =
  ## The team that has just scored, or -1. A goal is scored the moment the
  ## ball CENTRE crosses the goal line inside the mouth band.
  if ballY < GoalYMin or ballY > GoalYMax:
    return -1
  if ballX <= PitchXMin:
    return int32(ord(Blue))     ## into Red's net.
  if ballX >= PitchXMax:
    return int32(ord(Red))
  -1

proc sixYardCorner*(team: Team, y: int32): tuple[x, y: int32] =
  ## The corner of a team's own six-yard box nearest a crossing point — the
  ## goal-kick spot.
  let
    gx = if team == Red: PitchXMin + SixYardDepth
         else: PitchXMax - SixYardDepth
    gy = if y >= CentreY: CentreY + SixYardHalfH else: CentreY - SixYardHalfH
  (gx, gy)

proc sixYardCentre*(team: Team): tuple[x, y: int32] =
  let gx = if team == Red: PitchXMin + SixYardDepth
           else: PitchXMax - SixYardDepth
  (gx, CentreY)

proc cornerArc*(x, y: int32): tuple[x, y: int32] =
  ## The corner arc nearest a goal-line crossing.
  let
    cx = if x <= CentreX: PitchXMin else: PitchXMax
    cy = if y >= CentreY: PitchYMax else: PitchYMin
  (cx, cy)

proc freeKickSpot*(team: Team, x, y: int32): tuple[x, y: int32] =
  ## A free kick to `team` at (x, y), clamped out of the defending penalty
  ## area: never closer than 16 m to the goal line the OTHER team defends is
  ## not the rule — the rule is that a foul inside a penalty area is taken on
  ## the 16 m line, so the spot is pushed off the goal line of the area it is
  ## in. No penalties exist in v1 (docs/RULES.md §Out of scope).
  var (fx, fy) = clampToPitch(x, y)
  let defender = other(team)
  if inPenaltyArea(defender, fx, fy):
    fx = if defender == Red: PitchXMin + PenaltyDepth
         else: PitchXMax - PenaltyDepth
  (fx, fy)

proc nearestDropSpot*(x, y: int32): tuple[x, y: int32] =
  ## The drop spot nearest a point, in the fixed table order so ties resolve
  ## deterministically toward the earlier entry.
  var
    best = DropSpots[0]
    bestD = high(int64)
  for spot in DropSpots:
    let
      dx = int64(spot.x) - int64(x)
      dy = int64(spot.y) - int64(y)
      d = dx * dx + dy * dy
    if d < bestD:
      bestD = d
      best = spot
  best
