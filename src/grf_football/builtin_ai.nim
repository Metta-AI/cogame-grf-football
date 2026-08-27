## The built-in AI: the engine-side "rest of the team".
##
## It drives the fourteen unseated shirts (including both keepers), and its
## on-ball rule is also the SAFE OPTION the control layer falls back to when a
## seat's declared `on_ball` is illegal. A pure function of `(sim, cogIndex)`
## with NO RNG — deliberately disciplined but unimaginative: it holds shape,
## tackles when the ball is at its feet, passes to the nearest better-placed
## teammate and never carries the ball far.
##
## It DEFERS to a seated shirt: when a seated cog and a built-in cog of the
## same team are both within 3 m of a loose ball, the built-in cog yields and
## steers to a support point instead. That is what makes the eight seats, not
## the engine, decide matches.
##
## Integer only: no floating point, no libm. tests/test_determinism.nim greps
## this file.

import sim

const
  YieldRadius* = 3_000_000'i32   ## a built-in cog yields inside this.
  ChaseSprintDist* = 6_000_000'i32
  PressRadius* = 2_500_000'i32
  ShootRange* = 20_000_000'i32
  CarryRange* = 8_000_000'i32
  SupportOffset* = 9_000_000'i32
  KeeperArc* = 2_000_000'i32
  KeeperYSpan* = 3_500_000'i32
  TackleRadius* = 1_600_000'i32
  AnchorPullPct* = 30'i32
  ZoneBand* = 18_000_000'i32
  ArriveUm* = 400_000'i32

proc ballSpeed*(sim: SimServer): int32 {.inline.} =
  speedOf(sim.ball.vx, sim.ball.vy)

proc distToBall*(sim: SimServer, index: int): int32 {.inline.} =
  distI(sim.ball.x - sim.cogs[index].x, sim.ball.y - sim.cogs[index].y)

proc nearestOpponent*(sim: SimServer, index: int): int =
  let team = teamOfCog(index)
  var
    best = -1
    bestD = high(int32)
  for j in 0 ..< CogCount:
    if teamOfCog(j) == team:
      continue
    let d = distI(sim.cogs[j].x - sim.cogs[index].x,
      sim.cogs[j].y - sim.cogs[index].y)
    if d < bestD:
      bestD = d
      best = j
  best

proc nearestOpponentDist*(sim: SimServer, index: int): int32 =
  let j = sim.nearestOpponent(index)
  if j < 0: high(int32) else: distI(sim.cogs[j].x - sim.cogs[index].x,
    sim.cogs[j].y - sim.cogs[index].y)

proc nearestOfTeamToBall*(sim: SimServer, team: Team, skip = -1): int =
  ## The team's cog closest to the ball, keeper excluded; ties by ascending
  ## index so the choice is deterministic.
  var
    best = -1
    bestD = high(int32)
  for j in 0 ..< CogsPerTeam:
    let i = firstCogOf(team) + j
    if i == skip or isKeeper(i):
      continue
    let d = sim.distToBall(i)
    if d < bestD:
      bestD = d
      best = i
  if best < 0: firstCogOf(team) + 1 else: best

proc ballIsLoose*(sim: SimServer): bool {.inline.} =
  sim.ball.controller < 0

proc teamInPossession*(sim: SimServer): int32 {.inline.} =
  if sim.ball.controller >= 0:
    int32(ord(teamOfCog(int(sim.ball.controller))))
  else:
    -1

proc translatedAnchor*(sim: SimServer, index: int): tuple[x, y: int32] =
  ## The shirt's formation anchor pulled 30 % toward the ball and clamped to
  ## its own zone band, so a full back never ends up at the far post.
  let
    team = teamOfCog(index)
    shirt = int(sim.cogs[index].shirt)
    ax = anchorXFor(team, shirt)
    ay = anchorYFor(team, shirt)
    px = ax + pctScale(sim.ball.x - CentreX, AnchorPullPct)
    py = ay + pctScale(sim.ball.y - CentreY, AnchorPullPct)
  (clamp(clamp(px, ax - ZoneBand, ax + ZoneBand), PitchXMin, PitchXMax),
   clamp(clamp(py, ay - ZoneBand, ay + ZoneBand), PitchYMin, PitchYMax))

proc interceptPoint*(sim: SimServer, index: int): tuple[x, y: int32] =
  ## Where a chasing cog should run: the ball plus its velocity over a lead
  ## time derived from the closing speed, capped at two seconds.
  let
    dist = sim.distToBall(index)
    denom = max(1'i32, int32(sim.config.baseSpeed) + sim.ballSpeed())
    tau = clamp(dist div denom, 0'i32, 48'i32)
  (clamp(sim.ball.x + int32(int64(sim.ball.vx) * int64(tau)),
     PitchXMin, PitchXMax),
   clamp(sim.ball.y + int32(int64(sim.ball.vy) * int64(tau)),
     PitchYMin, PitchYMax))

proc supportPoint*(sim: SimServer, index: int): tuple[x, y: int32] =
  ## Nine metres beside the ball on the own-goal side, on the free flank.
  let
    team = teamOfCog(index)
    dir = attackDir(team)
    side = if sim.cogs[index].y >= sim.ball.y: SupportOffset
           else: -SupportOffset
  (clamp(sim.ball.x - SupportOffset * dir div 2, PitchXMin, PitchXMax),
   clamp(sim.ball.y + side, PitchYMin, PitchYMax))

proc seatedTeammateOnBall*(sim: SimServer, index: int): bool =
  ## True when a SEATED teammate is also within YieldRadius of a loose ball —
  ## the yield rule that keeps the eight seats decisive.
  if not sim.ballIsLoose():
    return false
  if sim.distToBall(index) > YieldRadius:
    return false
  let team = teamOfCog(index)
  for j in 0 ..< CogsPerTeam:
    let i = firstCogOf(team) + j
    if i == index or sim.cogs[i].seat < 0:
      continue
    if sim.distToBall(i) <= YieldRadius:
      return true
  false

proc laneClear*(sim: SimServer, fromIndex, toIndex: int): bool =
  ## No opponent within 1.2 m of the segment between two cogs. A cheap integer
  ## point-segment test: project, clamp, measure.
  let
    team = teamOfCog(fromIndex)
    ax = sim.cogs[fromIndex].x
    ay = sim.cogs[fromIndex].y
    bx = sim.cogs[toIndex].x
    by = sim.cogs[toIndex].y
    # MILLIMETRES, not micrometres: the projection takes a product of two
    # world-scale deltas and then scales it by 1024, which at micrometre scale
    # reaches 1.7e19 and leaves int64 behind. Dividing by 1000 first caps the
    # product at 8.3e12 with no loss that matters to a 1.2 m clearance test.
    dx = (int64(bx) - int64(ax)) div 1000
    dy = (int64(by) - int64(ay)) div 1000
    len2 = dx * dx + dy * dy
  if len2 <= 0:
    return true
  for j in 0 ..< CogCount:
    if teamOfCog(j) == team:
      continue
    let
      px = (int64(sim.cogs[j].x) - int64(ax)) div 1000
      py = (int64(sim.cogs[j].y) - int64(ay)) div 1000
    var t = (px * dx + py * dy) * 1024 div len2
    t = clamp(t, 0'i64, 1024'i64)
    let
      cx = int64(ax) + dx * 1000 * t div 1024
      cy = int64(ay) + dy * 1000 * t div 1024
      ex = int32(int64(sim.cogs[j].x) - cx)
      ey = int32(int64(sim.cogs[j].y) - cy)
    if distI(ex, ey) < 1_200_000'i32:
      return false
  true

proc shootingLaneClear*(sim: SimServer, index: int): bool =
  ## No TEAMMATE and no more than one opponent inside the cone between this
  ## cog and the goal mouth centre — the "clear cone" the safe option wants.
  let
    team = teamOfCog(index)
    gx = targetGoalX(team)
    ax = sim.cogs[index].x
    ay = sim.cogs[index].y
    dx = (int64(gx) - int64(ax)) div 1000
    dy = (int64(CentreY) - int64(ay)) div 1000
    len2 = dx * dx + dy * dy
  if len2 <= 0:
    return false
  var blockers = 0
  for j in 0 ..< CogCount:
    if j == index:
      continue
    let
      px = (int64(sim.cogs[j].x) - int64(ax)) div 1000
      py = (int64(sim.cogs[j].y) - int64(ay)) div 1000
    var t = (px * dx + py * dy) * 1024 div len2
    if t <= 0 or t >= 1024:
      continue
    t = clamp(t, 0'i64, 1024'i64)
    let
      cx = int64(ax) + dx * 1000 * t div 1024
      cy = int64(ay) + dy * 1000 * t div 1024
      ex = int32(int64(sim.cogs[j].x) - cx)
      ey = int32(int64(sim.cogs[j].y) - cy)
    if distI(ex, ey) < 1_500_000'i32:
      if teamOfCog(j) == team:
        return false
      inc blockers
  blockers <= 1

proc bestPassMate*(sim: SimServer, index: int, maxRange: int32): int =
  ## The best `passScore` teammate in range, cone-free — the target the safe
  ## option aims at. The direction bits the caller emits are what actually
  ## select the receiver inside the sim, so the caller must point at this cog.
  let team = teamOfCog(index)
  var
    best = -1
    bestScore = low(int64)
  for j in 0 ..< CogCount:
    if j == index or teamOfCog(j) != team:
      continue
    let d = distI(sim.cogs[j].x - sim.cogs[index].x,
      sim.cogs[j].y - sim.cogs[index].y)
    if d <= 0 or d > maxRange:
      continue
    let score = sim.passScore(j)
    if score > bestScore:
      bestScore = score
      best = j
  best

proc mostAdvancedOpen*(sim: SimServer, index: int, maxRange: int32): int =
  ## The teammate furthest up-field that is not tightly marked.
  let
    team = teamOfCog(index)
    dir = attackDir(team)
  var
    best = -1
    bestX = low(int64)
  for j in 0 ..< CogCount:
    if j == index or teamOfCog(j) != team:
      continue
    let d = distI(sim.cogs[j].x - sim.cogs[index].x,
      sim.cogs[j].y - sim.cogs[index].y)
    if d <= 0 or d > maxRange:
      continue
    if sim.nearestOpponentDist(j) < 2_000_000'i32:
      continue
    let x = int64(sim.cogs[j].x) * int64(dir)
    if x > bestX:
      bestX = x
      best = j
  best

proc dirTowardCog(sim: SimServer, fromIndex, toIndex: int): int32 {.inline.} =
  dirOfVector(sim.cogs[toIndex].x - sim.cogs[fromIndex].x,
    sim.cogs[toIndex].y - sim.cogs[fromIndex].y)

proc safeOnBall*(sim: SimServer, index: int): tuple[code, dir: int32] =
  ## The built-in AI's on-ball rule, and the control layer's safe option.
  let
    team = teamOfCog(index)
    gx = targetGoalX(team)
    goalDist = distI(gx - sim.cogs[index].x, CentreY - sim.cogs[index].y)
    pressure = sim.nearestOpponentDist(index)
  if pressure < PressRadius:
    let mate = sim.bestPassMate(index, ShortPassRange)
    if mate >= 0:
      return (1'i32, sim.dirTowardCog(index, mate))
  if goalDist <= ShootRange and sim.shootingLaneClear(index):
    return (4'i32, dirOfVector(gx - sim.cogs[index].x,
      CentreY - sim.cogs[index].y))
  if pressure > ChaseSprintDist:
    # Carry: no code, just run at the goal. `CarryRange` is the re-evaluation
    # distance, not a hard stop — the rule re-runs every tick.
    return (0'i32, dirOfVector(gx - sim.cogs[index].x,
      CentreY - sim.cogs[index].y))
  let advanced = sim.mostAdvancedOpen(index, LongPassRange)
  if advanced >= 0:
    if not sim.laneClear(index, advanced) and
        distI(sim.cogs[advanced].x - sim.cogs[index].x,
          sim.cogs[advanced].y - sim.cogs[index].y) > 25_000_000'i32:
      return (3'i32, sim.dirTowardCog(index, advanced))
    return (2'i32, sim.dirTowardCog(index, advanced))
  let mate = sim.bestPassMate(index, ShortPassRange)
  if mate >= 0:
    return (1'i32, sim.dirTowardCog(index, mate))
  (0'i32, dirOfVector(gx - sim.cogs[index].x, CentreY - sim.cogs[index].y))

proc mostOpenBeyondHalfway*(sim: SimServer, index: int): int =
  ## The teammate with the most space around it, on the far side of the halfway
  ## line and inside long-pass range — the keeper's goal-kick target.
  let
    team = teamOfCog(index)
    dir = attackDir(team)
  var
    best = -1
    bestOpen = low(int32)
  for j in 0 ..< CogCount:
    if j == index or teamOfCog(j) != team:
      continue
    if int64(sim.cogs[j].x - CentreX) * int64(dir) <= 0:
      continue
    let d = distI(sim.cogs[j].x - sim.cogs[index].x,
      sim.cogs[j].y - sim.cogs[index].y)
    if d <= 0 or d > LongPassRange:
      continue
    let open = sim.nearestOpponentDist(j)
    if open > bestOpen:
      bestOpen = open
      best = j
  best

proc nearestFullBack*(sim: SimServer, index: int): int =
  ## The nearer of the two full backs (shirts 2 and 3) — the keeper's short
  ## option when nothing is on beyond the halfway line.
  let team = teamOfCog(index)
  var
    best = -1
    bestD = high(int32)
  for shirt in [2, 3]:
    let j = cogOfShirt(team, shirt)
    if j == index:
      continue
    let d = distI(sim.cogs[j].x - sim.cogs[index].x,
      sim.cogs[j].y - sim.cogs[index].y)
    if d < bestD:
      bestD = d
      best = j
  best

proc keeperOnBall*(sim: SimServer, index: int): tuple[code, dir: int32] =
  ## Design note §The built-in AI item 1: on possession the keeper plays a goal
  ## kick — `pass_long` to the most open teammate beyond the halfway line, else
  ## `pass_short` to the nearest full back. A keeper does not run the outfield
  ## safe option, whose first branch under pressure is a short pass and whose
  ## second is a SHOT (its own goal is behind it, so `goalDist` is the length of
  ## the pitch and the shot never fires — it carried the ball out of its area
  ## instead).
  let long = sim.mostOpenBeyondHalfway(index)
  if long >= 0:
    return (2'i32, sim.dirTowardCog(index, long))
  let back = sim.nearestFullBack(index)
  if back >= 0:
    return (1'i32, sim.dirTowardCog(index, back))
  sim.safeOnBall(index)

proc wantsTackle*(sim: SimServer, index: int): bool =
  ## Deterministic, never probabilistic: an opponent controls the ball inside
  ## TackleRadius and this cog is closing on it within 45 degrees.
  if sim.cogs[index].groundedTicks > 0 or sim.cogs[index].slideTicks > 0:
    return false
  if sim.ball.controller < 0:
    return false
  let holder = int(sim.ball.controller)
  if teamOfCog(holder) == teamOfCog(index):
    return false
  let d = sim.distToBall(index)
  if d > TackleRadius or d <= 0:
    return false
  let
    tx = sim.ball.x - sim.cogs[index].x
    ty = sim.ball.y - sim.cogs[index].y
    vx = sim.cogs[index].vx
    vy = sim.cogs[index].vy
    v = distI(vx, vy)
  if v <= 0:
    return true
  # cos(45 deg) >= 0.7071  <=>  dot * 10000 >= d * v * 7071
  let dot = int64(tx) * int64(vx) + int64(ty) * int64(vy)
  dot * 10000 >= int64(d) * int64(v) * 7071

proc keeperTarget(sim: SimServer, index: int): tuple[x, y: int32] =
  let
    team = teamOfCog(index)
    dir = attackDir(team)
    onLineX = ownGoalX(team) + KeeperArc * dir
    y = CentreY + clamp((sim.ball.y - CentreY) div 2,
      -KeeperYSpan, KeeperYSpan)
  # Come off the line when the ball is inside the six-yard box and no defender
  # is closer to it than the keeper.
  if inSixYardBox(team, sim.ball.x, sim.ball.y):
    var closer = false
    for j in 1 ..< CogsPerTeam:
      let i = firstCogOf(team) + j
      if sim.distToBall(i) < sim.distToBall(index):
        closer = true
        break
    if not closer:
      return (sim.ball.x, sim.ball.y)
  (onLineX, y)

proc steerAction*(
  sim: SimServer,
  index: int,
  px, py: int32,
  sprint: bool,
  code: int32,
  codeDir: int32,
  chasing = false
): uint8 =
  ## Turns a steering point into one action byte. The direction nibble is 0
  ## when the cog has arrived and is not chasing the ball, so an arrived cog
  ## stands still instead of jittering across its target. A CHASING cog keeps
  ## its bits: its steering point is the interception point, which the ball is
  ## leaving, so dropping the nibble there parks the cog next to a loose ball.
  var dir =
    if code >= 1 and code <= 4: codeDir
    else: dirOfVector(px - sim.cogs[index].x, py - sim.cogs[index].y)
  if (code < 1 or code > 4) and not chasing:
    let d = distI(px - sim.cogs[index].x, py - sim.cogs[index].y)
    if d < ArriveUm:
      dir = 0
  encodeAction(dir, code, sprint)

proc builtinAction*(sim: SimServer, index: int): uint8 =
  ## One unseated shirt's action byte for one tick.
  let
    team = teamOfCog(index)
    possession = sim.teamInPossession()
    mine = int32(ord(team))
  var
    px = sim.cogs[index].x
    py = sim.cogs[index].y
    sprint = false
    code = 0'i32
    codeDir = 0'i32

  if sim.ball.controller == int32(index):
    let onBall =
      if isKeeper(index): sim.keeperOnBall(index)
      else: sim.safeOnBall(index)
    code = onBall.code
    codeDir = onBall.dir
    if isKeeper(index):
      # A keeper with the ball goes nowhere: it is releasing it. Steering at the
      # far goal would walk it out of its own area if the release is dropped.
      let t = sim.keeperTarget(index)
      px = t.x
      py = t.y
    else:
      let gx = targetGoalX(team)
      px = gx
      py = CentreY
    # Dribble mode is always in a defined state: on when carrying under
    # pressure, off otherwise.
    if code == 0:
      let close = sim.nearestOpponentDist(index) < 5_000_000'i32
      if close and not sim.cogs[index].dribbling: code = 6
      elif not close and sim.cogs[index].dribbling: code = 7
    return sim.steerAction(index, px, py, sprint, code, codeDir)

  if isKeeper(index):
    let t = sim.keeperTarget(index)
    px = t.x
    py = t.y
  else:
    let chaser = sim.nearestOfTeamToBall(team)
    let cover = sim.nearestOfTeamToBall(team, chaser)
    if possession == mine:
      let anchor = sim.translatedAnchor(index)
      px = anchor.x
      py = anchor.y
      let shirt = int(sim.cogs[index].shirt)
      if shirt == 9 or shirt == 11 or shirt == 7:
        px = clamp(px + 8_000_000'i32 * attackDir(team),
          PitchXMin, PitchXMax)
      if index == chaser:
        let s = sim.supportPoint(index)
        px = s.x
        py = s.y
    else:
      if index == chaser and not sim.seatedTeammateOnBall(index):
        let p = sim.interceptPoint(index)
        px = p.x
        py = p.y
        sprint = sim.distToBall(index) > ChaseSprintDist
      elif index == cover and sim.ball.controller >= 0:
        px = int32((int64(sim.ball.x) + int64(ownGoalX(team))) div 2)
        py = int32((int64(sim.ball.y) + int64(CentreY)) div 2)
      else:
        let anchor = sim.translatedAnchor(index)
        let mark = sim.nearestOpponent(index)
        if mark >= 0:
          px = int32((int64(anchor.x) + int64(sim.cogs[mark].x)) div 2)
          py = int32((int64(anchor.y) + int64(sim.cogs[mark].y)) div 2)
        else:
          px = anchor.x
          py = anchor.y

  if sim.wantsTackle(index):
    code = 5
  elif sim.cogs[index].dribbling:
    code = 7
  sim.steerAction(index, px, py, sprint, code, codeDir)
