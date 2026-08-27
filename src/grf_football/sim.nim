## The deterministic gameplay core: the integer physics, the 19-action byte,
## the pass/shot/slide model, the restart table, the stalemate drop and the
## per-tick step loop. Types, consts, pitch geometry, config and state services
## live in the sibling modules this file imports and re-exports, exactly as
## ctf's `sim.nim` does.
##
## THE DETERMINISM CONTRACT (docs/RULES.md §Determinism):
##
## * every stored field is an explicit `int32` / `bool` / enum — never a bare
##   `int`, which is 64-bit natively and 32-bit under `--cpu:wasm32`;
## * every product or quotient of two sim quantities is taken in `int64` and
##   narrowed with an explicit truncating `div` (Nim's `div` truncates toward
##   zero, so the arithmetic is symmetric under negation — which is what makes
##   the two ends of the pitch exactly fair);
## * there is no floating point in this module, and no libm call anywhere: the
##   only trigonometry is the committed `SinQ12` table in `trig.nim`, the only
##   square root is `isqrt`, and the only atan2 is `bradsOfVectorI`.
##
## The recorded action log is the 22 cogs' one-byte gfootball actions. The
## control layer, the built-in AI, the LLM and the directive records are all
## OUTSIDE this boundary: the wasm viewer never runs them, it feeds the
## recorded bytes to this identical core.
##
## ONE CONSEQUENCE WORTH STATING. A directive's `pass_to` cannot be read here:
## directives are not in the replay's action log and the viewer has no access
## to them, so a pass target chosen from a directive would diverge on
## re-simulation. The receiver is therefore always chosen from the ACTION BYTE
## plus sim state — the direction nibble is the cone — and `control.nim` is
## what points those direction bits at the named teammate.

import
  std/random

import sim_types, trig, pitch, sim_config, sim_state
export sim_types, trig, pitch, sim_config, sim_state

# --------------------------------------------------------------------------
# Small integer helpers. Every one of these takes its product in int64.
# --------------------------------------------------------------------------

proc q12Scale*(value, unit: int32): int32 {.inline.} =
  ## value * unit / 4096, where `unit` is a Q12 direction component.
  int32((int64(value) * int64(unit)) div 4096)

proc pctScale*(value: int32, pct: int32): int32 {.inline.} =
  int32((int64(value) * int64(pct)) div 100)

proc permilScale*(value: int32, num: int32): int32 {.inline.} =
  ## value * num / 1024 — the drag unit.
  int32((int64(value) * int64(num)) div 1024)

proc speedOf*(vx, vy: int32): int32 {.inline.} =
  distI(vx, vy)

proc capSpeed*(vx, vy: var int32, cap: int32) {.inline.} =
  let s = speedOf(vx, vy)
  if s > cap and s > 0:
    vx = int32((int64(vx) * int64(cap)) div int64(s))
    vy = int32((int64(vy) * int64(cap)) div int64(s))

proc unitQ12*(dx, dy: int32): tuple[x, y, d: int32] {.inline.} =
  ## A Q12 unit vector plus the length it was derived from. A zero vector
  ## resolves to east, so nothing in the sim can divide by zero.
  let d = distI(dx, dy)
  if d <= 0:
    return (4096'i32, 0'i32, 0'i32)
  (int32((int64(dx) * 4096) div int64(d)),
   int32((int64(dy) * 4096) div int64(d)), d)

proc dirOfVector*(dx, dy: int32): int32 =
  ## The 8-way quantisation of a world delta into a direction nibble 1..8.
  ## Uses the integer atan2 and rounds to the nearest compass point, so it is
  ## exactly antisymmetric under (dx, dy) -> (dx, -dy).
  if dx == 0 and dy == 0:
    return 0
  let b = bradsOfVectorI(dx, dy)
  # Compass points sit 32 brads apart starting at 0 = east.
  let step = ((b + 16) div 32) mod 8
  case step
  of 0: 3'i32   ## E
  of 1: 2'i32   ## NE
  of 2: 1'i32   ## N
  of 3: 8'i32   ## NW
  of 4: 7'i32   ## W
  of 5: 6'i32   ## SW
  of 6: 5'i32   ## S
  else: 4'i32   ## SE

# --------------------------------------------------------------------------
# Accessors
# --------------------------------------------------------------------------

proc effectiveMaxTicks*(sim: SimServer): int {.inline.} =
  sim.config.maxTicks

proc turnTicks*(sim: SimServer): int {.inline.} =
  max(1, sim.config.turnTicks)

proc turnCount*(sim: SimServer): int {.inline.} =
  max(1, sim.config.maxTicks div sim.turnTicks())

proc gameTicksElapsed*(sim: SimServer): int {.inline.} =
  if sim.gameStartTick < 0: 0 else: max(0, sim.tickCount - sim.gameStartTick)

proc currentTurn*(sim: SimServer): int {.inline.} =
  sim.gameTicksElapsed() div sim.turnTicks()

proc goals*(sim: SimServer, team: Team): int {.inline.} =
  int(sim.teamStats[team].goals)

proc goalDiff*(sim: SimServer, team: Team): int {.inline.} =
  sim.goals(team) - sim.goals(other(team))

proc seatOfCog*(sim: SimServer, index: int): int {.inline.} =
  ## -1 for a built-in AI shirt.
  if index < 0 or index >= CogCount: -1 else: int(sim.cogs[index].seat)

proc isKeeper*(index: int): bool {.inline.} =
  (index mod CogsPerTeam) == 0

proc modeSpeed*(sim: SimServer, index: int): int32 =
  ## The cog's speed cap this tick, from its modes and its stamina.
  let cog = sim.cogs[index]
  var base =
    if cog.dribbling: DribbleSpeed
    elif cog.sprinting: int32(sim.config.sprintSpeed)
    elif isKeeper(index): KeeperSpeed
    else: int32(sim.config.baseSpeed)
  if cog.stamina < TiredStamina:
    base = pctScale(base, TiredSpeedPct)
  base

# --------------------------------------------------------------------------
# Construction and placement
# --------------------------------------------------------------------------

proc formationReset*(sim: var SimServer, kickingTeam: int32, staminaBoost: int32)

proc initSimServer*(config: GameConfig): SimServer =
  ## Builds a fresh sim from a resolved config. No sockets, no rendering.
  result.config = config
  result.rng = initRand(config.seed)
  result.phase = Lobby
  result.winner = Red
  result.endReason = reasonComplete
  result.endRule = erFullTime
  result.gameStartTick = -1
  result.half = 1
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1
  result.lastTouch = Touch(cog: -1, team: -1, tick: -1)
  result.prevTouch = Touch(cog: -1, team: -1, tick: -1)
  result.pendingPass = PassRecord(team: -1, cog: -1, tick: -1, target: -1)
  result.pendingShotTeam = -1
  result.pendingShotCog = -1
  result.pendingShotTick = -1
  result.lastGoalTick = -1
  result.lastGoalTeam = -1
  result.lastGoalBy = -1
  result.lastGoalAssist = -1
  result.lastDropTick = -1
  result.lastRestartTick = -1
  result.lastHalfTimeTick = -1
  result.gameEventLoggingEnabled = true
  for i in 0 ..< CogCount:
    let team = teamOfCog(i)
    result.cogs[i].team = int32(ord(team))
    result.cogs[i].shirt = int32((i mod CogsPerTeam) + 1)
    result.cogs[i].seat = -1
    result.cogs[i].stamina = StaminaMax
  for seat in 0 ..< SeatCount:
    let index = cogOfSeat(seat)
    if index >= 0:
      result.cogs[index].seat = int32(seat)
  # Every cog has a directive from tick zero, so no failure mode — not even a
  # turn that never ran — can leave one unactuated.
  for seat in 0 ..< SeatCount:
    let index = cogOfSeat(seat)
    result.activeDirective[seat] = Directive(
      turn: 0, half: 1, source: dsScripted, note: "",
      cog: CogOrder(
        role: SeatRole[seat], intent: inSupport,
        targetX: CentreX, targetY: CentreY,
        onBall: obPassShort, passTo: -1,
        sprint: spAuto, tackle: tkAuto, say: ""))
    discard index
  result.formationReset(int32(config.seed and 1), StaminaMax)
  # The construction-time placement is not a kickoff — the match has not
  # started — so the beat field it just set is cleared again. `startGame`'s own
  # reset is the first real one.
  result.lastRestartTick = -1

proc placeCog(sim: var SimServer, index: int, x, y: int32) =
  sim.cogs[index].x = x
  sim.cogs[index].y = y
  sim.cogs[index].vx = 0
  sim.cogs[index].vy = 0
  sim.cogs[index].dir = 0
  sim.cogs[index].sprinting = false
  sim.cogs[index].dribbling = false
  sim.cogs[index].slideTicks = 0
  sim.cogs[index].groundedTicks = 0
  sim.cogs[index].passCooldown = 0
  sim.cogs[index].shotCooldown = 0
  sim.cogs[index].slideDirX = 0
  sim.cogs[index].slideDirY = 0
  sim.cogs[index].slideTouchedBall = false

proc clearPossessionChain(sim: var SimServer) =
  ## A restart clears the chain: otherwise a pass, an interception or a save
  ## would be credited across it, to a touch made ten seconds ago at the other
  ## end of the pitch.
  sim.lastTouch = Touch(cog: -1, team: -1, tick: -1)
  sim.prevTouch = Touch(cog: -1, team: -1, tick: -1)
  sim.pendingPass = PassRecord(team: -1, cog: -1, tick: -1, target: -1)
  sim.pendingShotTeam = -1
  sim.pendingShotCog = -1
  sim.pendingShotTick = -1

proc beginRestart*(
  sim: var SimServer,
  kind: RestartKind,
  team: int32,
  taker: int32,
  spotX, spotY: int32
) =
  ## Enters a dead-ball phase: the ball sits on the spot and cannot be touched
  ## for `restartTicks`, the taker is snapped behind it, and every opponent
  ## inside RestartClearRadius is pushed radially out. All other cogs keep
  ## moving under their own control (they spread and mark).
  sim.restartKind = kind
  sim.restartTeam = team
  sim.restartTaker = taker
  sim.restartTicks = int32(max(1, sim.config.restartTicks))
  sim.restartX = spotX
  sim.restartY = spotY
  sim.ball = Ball(x: spotX, y: spotY, vx: 0, vy: 0, z: 0, vz: 0,
    controller: -1, dead: true)
  sim.stalemateTicks = 0
  sim.anchorX = spotX
  sim.anchorY = spotY
  sim.clearPossessionChain()
  sim.emitEvent(Restart, source = int(taker), team = int(team),
    x = spotX, y = spotY, content = restartText(kind))

proc formationReset*(
  sim: var SimServer,
  kickingTeam: int32,
  staminaBoost: int32
) =
  ## Every cog to its shirt's formation anchor in its own half, all velocities,
  ## modes and timers zeroed, stamina restored, then the kickoff restart.
  ##
  ## Each cog gets a deterministic Y jitter drawn from the seeded sim RNG —
  ## the idea's "seeded kick-offs". The draws happen in cog index order on both
  ## sides of the native/wasm boundary, so playback reconstructs them exactly.
  let kicking = Team(kickingTeam and 1)
  for i in 0 ..< CogCount:
    let
      team = teamOfCog(i)
      shirt = int(sim.cogs[i].shirt)
      jitter = int32(sim.rng.rand(600_000) - 300_000)
    let
      ax = anchorXFor(team, shirt)
      ay = clamp(anchorYFor(team, shirt) + jitter, PitchYMin, PitchYMax)
    sim.placeCog(i, ax, ay)
    sim.cogs[i].stamina =
      if staminaBoost >= StaminaMax: StaminaMax
      else: min(StaminaMax, sim.cogs[i].stamina + staminaBoost)
  # The kicking team's shirt 10 stands just behind the ball; everyone else is
  # already outside the centre circle by construction of the 4-3-3 anchors.
  let taker = cogOfShirt(kicking, 10)
  sim.placeCog(taker,
    CentreX - RestartTakerOffset * attackDir(kicking), CentreY)
  sim.beginRestart(rkKickoff, int32(ord(kicking)), int32(taker),
    CentreX, CentreY)

proc neutralDrop(sim: var SimServer) =
  ## The stalemate cure, INSIDE the sim so no policy can defeat it.
  let spot = nearestDropSpot(sim.ball.x, sim.ball.y)
  for i in 0 ..< CogCount:
    let
      dx = sim.cogs[i].x - spot.x
      dy = sim.cogs[i].y - spot.y
      u = unitQ12(dx, dy)
    if u.d < RestartClearRadius:
      sim.cogs[i].x = spot.x + q12Scale(RestartClearRadius, u.x)
      sim.cogs[i].y = spot.y + q12Scale(RestartClearRadius, u.y)
      sim.cogs[i].vx = 0
      sim.cogs[i].vy = 0
  sim.beginRestart(rkDrop, -1, -1, spot.x, spot.y)
  sim.lastDropTick = int32(sim.tickCount)
  sim.emitEvent(Drop, x = spot.x, y = spot.y)
  sim.logGameEvent("neutral drop at " & $spot.x & "," & $spot.y)

# --------------------------------------------------------------------------
# Endings
# --------------------------------------------------------------------------

proc finishGame*(sim: var SimServer, reason: EndReason, rule: EndRule) =
  ## Ends the match. Idempotent: the first ending wins, so a wall-clock stop
  ## landing on the same tick as full time cannot overwrite the verdict.
  if sim.phase == GameOver:
    return
  sim.endReason = reason
  sim.endRule = rule
  sim.ended = true
  let diff = sim.goalDiff(Red)
  if reason == reasonFault or diff == 0:
    sim.isDraw = true
    sim.winner = Red
  else:
    sim.isDraw = false
    sim.winner = if diff > 0: Red else: Blue
  sim.emitPhaseChange(GameOver)
  sim.phase = GameOver
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.logGameEvent("game over: " & reasonText(reason) & "/" &
    endRuleText(rule) & " " & $sim.goals(Red) & "-" & $sim.goals(Blue))

proc startGame*(sim: var SimServer) =
  sim.emitPhaseChange(Playing)
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.half = 1
  sim.formationReset(int32(sim.config.seed and 1), StaminaMax)
  sim.logGameEvent("kick off, first half, restart team " & $sim.restartTeam)

# --------------------------------------------------------------------------
# Possession bookkeeping
# --------------------------------------------------------------------------

proc recordTouch(sim: var SimServer, index: int) =
  ## One cog touching the ball: pass/interception attribution, save detection
  ## and the possession chain. Derived from STATE alone — declared intent lives
  ## outside the determinism boundary, so it cannot be read here.
  let team = teamOfCog(index)
  if sim.lastTouch.cog == int32(index):
    sim.lastTouch.tick = int32(sim.tickCount)
    return
  if sim.pendingPass.cog >= 0 and sim.pendingPass.cog != int32(index) and
      int32(sim.tickCount) - sim.pendingPass.tick <= PassWindowTicks:
    if sim.pendingPass.team == int32(ord(team)):
      inc sim.cogStats[int(sim.pendingPass.cog)].passesCompleted
      sim.emitEvent(Pass, source = int(sim.pendingPass.cog), target = index,
        team = ord(team), content = "complete")
    else:
      inc sim.cogStats[index].interceptions
      sim.emitEvent(Pass, source = int(sim.pendingPass.cog), target = index,
        team = ord(team), content = "intercepted")
    sim.pendingPass = PassRecord(team: -1, cog: -1, tick: -1, target: -1)
  if sim.pendingShotCog >= 0 and sim.pendingShotTeam != int32(ord(team)):
    if inPenaltyArea(team, sim.cogs[index].x, sim.cogs[index].y):
      inc sim.teamStats[team].saves
      sim.emitEvent(Save, source = index, team = ord(team))
    sim.pendingShotTeam = -1
    sim.pendingShotCog = -1
    sim.pendingShotTick = -1
  elif sim.pendingShotCog >= 0:
    sim.pendingShotTeam = -1
    sim.pendingShotCog = -1
    sim.pendingShotTick = -1
  sim.prevTouch = sim.lastTouch
  sim.lastTouch = Touch(cog: int32(index), team: int32(ord(team)),
    tick: int32(sim.tickCount))
  sim.emitEvent(TouchEvent, source = index, team = ord(team),
    x = sim.ball.x, y = sim.ball.y)

# --------------------------------------------------------------------------
# Pass and shot targeting
# --------------------------------------------------------------------------

proc opennessOf(sim: SimServer, index: int): int32 =
  ## Distance from a cog to the nearest opponent, in micrometres.
  let team = teamOfCog(index)
  var best = high(int32)
  for j in 0 ..< CogCount:
    if teamOfCog(j) == team:
      continue
    let d = distI(sim.cogs[j].x - sim.cogs[index].x,
      sim.cogs[j].y - sim.cogs[index].y)
    if d < best:
      best = d
  best

proc passScore*(sim: SimServer, index: int): int64 =
  ## `openness_mm - 2 * distance_to_own_goal_mm`. Millimetres, so the two terms
  ## are comparable at a human scale and the arithmetic stays well inside
  ## int64 on both targets.
  let
    team = teamOfCog(index)
    openness = int64(sim.opennessOf(index)) div 1000
    ownGoal = int64(distI(ownGoalX(team) - sim.cogs[index].x,
      CentreY - sim.cogs[index].y)) div 1000
  openness - 2 * ownGoal

proc bestReceiver*(
  sim: SimServer,
  passer: int,
  dir: int32,
  maxRange: int32
): int =
  ## The teammate with the best `passScore` inside a +-50 degree cone about the
  ## passer's direction bits and within `maxRange`. -1 when none qualifies.
  ##
  ## +-50 degrees is `cos(50 deg) >= 0.643`, taken as an exact integer test:
  ## `dot * 1000 >= dist * 643 * 4096 / 4096`. The cone opens fully when the
  ## direction nibble is 0 (release_direction), which is what makes a pass with
  ## no direction held still find a receiver instead of dying.
  let team = teamOfCog(passer)
  var
    best = -1
    bestScore = low(int64)
  let
    hasDir = dir >= 1 and dir <= 8
    ux = DirVecQ12[dir].x
    uy = DirVecQ12[dir].y
  for j in 0 ..< CogCount:
    if j == passer or teamOfCog(j) != team:
      continue
    let
      dx = sim.cogs[j].x - sim.cogs[passer].x
      dy = sim.cogs[j].y - sim.cogs[passer].y
      d = distI(dx, dy)
    if d <= 0 or d > maxRange:
      continue
    if hasDir:
      let dot = int64(dx) * int64(ux) + int64(dy) * int64(uy)
      # cos(theta) >= 0.643  <=>  dot / (d * 4096) >= 643/1000
      if dot * 1000 < int64(d) * 4096'i64 * 643'i64:
        continue
    let score = sim.passScore(j)
    if score > bestScore:
      bestScore = score
      best = j
  best

proc keeperOf(sim: SimServer, team: Team): int {.inline.} =
  firstCogOf(team)

proc shotAimPoint(sim: SimServer, team: Team): tuple[x, y: int32] =
  ## The goal-mouth point furthest from the defending keeper.
  let
    goalX = targetGoalX(team)
    keeper = sim.keeperOf(other(team))
    lo = GoalYMin + 400_000'i32
    hi = GoalYMax - 400_000'i32
    ky = sim.cogs[keeper].y
  if abs(int64(ky) - int64(lo)) >= abs(int64(ky) - int64(hi)):
    (goalX, lo)
  else:
    (goalX, hi)

proc registerShot(sim: var SimServer, index: int) =
  ## Classifies the ball's post-strike velocity ray against the opponent goal.
  let
    team = teamOfCog(index)
    goalX = targetGoalX(team)
    dx = int64(goalX) - int64(sim.ball.x)
    vx = int64(sim.ball.vx)
  inc sim.cogStats[index].shots
  inc sim.teamStats[team].shots
  var onTarget = false
  if vx != 0 and (dx > 0) == (vx > 0):
    let crossY = int64(sim.ball.y) + (int64(sim.ball.vy) * dx) div vx
    onTarget = crossY >= int64(GoalYMin) and crossY <= int64(GoalYMax)
  if onTarget:
    inc sim.cogStats[index].shotsOnTarget
    inc sim.teamStats[team].shotsOnTarget
    sim.pendingShotTeam = int32(ord(team))
    sim.pendingShotCog = int32(index)
    sim.pendingShotTick = int32(sim.tickCount)
  sim.emitEvent(Shot, source = index, team = ord(team),
    amount = ord(onTarget), x = sim.ball.x, y = sim.ball.y,
    speed = speedOf(sim.ball.vx, sim.ball.vy),
    content = (if onTarget: "on_target" else: "off_target"))

proc launchBall(sim: var SimServer, fromIndex: int, tx, ty, speed: int32,
    airborne: bool) =
  ## Sends the ball from a cog toward (tx, ty) at `speed`. A high pass follows
  ## an integer parabola whose apex is AirApex and whose flight lands on the
  ## target; everything else rolls.
  let u = unitQ12(tx - sim.cogs[fromIndex].x, ty - sim.cogs[fromIndex].y)
  sim.ball.x = sim.cogs[fromIndex].x + q12Scale(CogRadius + BallRadius, u.x)
  sim.ball.y = sim.cogs[fromIndex].y + q12Scale(CogRadius + BallRadius, u.y)
  sim.ball.vx = q12Scale(speed, u.x)
  sim.ball.vy = q12Scale(speed, u.y)
  sim.ball.controller = -1
  if airborne:
    # apex = vz^2 / (2 g)  =>  vz = isqrt(2 * g * apex)
    sim.ball.z = GroundZ
    sim.ball.vz = int32(isqrt(2'i64 * int64(Gravity) * int64(AirApex)))
  else:
    sim.ball.z = 0
    sim.ball.vz = 0

proc releaseOnBall(sim: var SimServer, index: int, code: int32, dir: int32) =
  ## Step 6 of the resolution order, for the cog in possession only.
  let team = teamOfCog(index)
  case code
  of 1, 2, 3:
    if sim.cogs[index].passCooldown > 0:
      return
    let
      speed =
        case code
        of 1: int32(sim.config.shortPassSpeed)
        of 2: int32(sim.config.longPassSpeed)
        else: HighPassSpeed
      maxRange =
        case code
        of 1: ShortPassRange
        of 2: LongPassRange
        else: HighPassRange
      receiver = sim.bestReceiver(index, dir, maxRange)
    if receiver < 0:
      return
    let
      tx = sim.cogs[receiver].x +
        int32(int64(sim.cogs[receiver].vx) * int64(PassLeadTicks))
      ty = sim.cogs[receiver].y +
        int32(int64(sim.cogs[receiver].vy) * int64(PassLeadTicks))
    sim.launchBall(index, tx, ty, speed, code == 3)
    sim.cogs[index].passCooldown = PassCooldownTicks
    inc sim.cogStats[index].passes
    inc sim.teamStats[team].passes
    sim.prevTouch = sim.lastTouch
    sim.lastTouch = Touch(cog: int32(index), team: int32(ord(team)),
      tick: int32(sim.tickCount))
    sim.pendingPass = PassRecord(team: int32(ord(team)), cog: int32(index),
      tick: int32(sim.tickCount), target: int32(receiver))
    sim.arcs.add ArcFx(x0: sim.cogs[index].x, y0: sim.cogs[index].y,
      x1: tx, y1: ty, tick: int32(sim.tickCount),
      team: int32(ord(team)), kind: 0)
    sim.emitEvent(Pass, source = index, target = receiver, team = ord(team),
      speed = speed,
      content = (case code
        of 1: "short"
        of 2: "long"
        else: "high"))
  of 4:
    if sim.cogs[index].shotCooldown > 0:
      return
    let aim = sim.shotAimPoint(team)
    # Aim error, in brads, from the seeded sim RNG: integer draws only, part
    # of the recorded seed, so the wasm re-simulation reproduces it exactly.
    let distM = int(distI(aim.x - sim.cogs[index].x,
      aim.y - sim.cogs[index].y)) div 1_000_000
    var e = 2 + distM div 6
    for j in 0 ..< CogCount:
      if teamOfCog(j) == team:
        continue
      if distI(sim.cogs[j].x - sim.cogs[index].x,
          sim.cogs[j].y - sim.cogs[index].y) <= 2_000_000'i32:
        e += 4
        break
    let err = int32(sim.rng.rand(2 * e) - e)
    let base = bradsOfVectorI(aim.x - sim.cogs[index].x,
      aim.y - sim.cogs[index].y)
    let b = ((base + err) mod 256 + 256) mod 256
    let
      speed = int32(sim.config.shotSpeed)
      tx = sim.cogs[index].x + q12Scale(40_000_000'i32, cosQ12(b))
      ty = sim.cogs[index].y - q12Scale(40_000_000'i32, sinQ12(b))
    sim.launchBall(index, tx, ty, speed, false)
    sim.cogs[index].shotCooldown = ShotCooldownTicks
    sim.prevTouch = sim.lastTouch
    sim.lastTouch = Touch(cog: int32(index), team: int32(ord(team)),
      tick: int32(sim.tickCount))
    sim.arcs.add ArcFx(x0: sim.cogs[index].x, y0: sim.cogs[index].y,
      x1: tx, y1: ty, tick: int32(sim.tickCount),
      team: int32(ord(team)), kind: 1)
    sim.registerShot(index)
  else:
    discard

# --------------------------------------------------------------------------
# Substeps
# --------------------------------------------------------------------------

proc integrateCogs(sim: var SimServer, actions: openArray[uint8]) =
  for i in 0 ..< CogCount:
    var cog = sim.cogs[i]
    if cog.slideTicks > 0:
      # A sliding cog cannot change direction; its velocity is already set.
      cog.x += cog.vx div Substeps
      cog.y += cog.vy div Substeps
      cog.distanceUm += int64(distI(cog.vx div Substeps, cog.vy div Substeps))
      sim.cogs[i] = cog
      continue
    let cap = sim.modeSpeed(i)
    if cog.groundedTicks > 0 or cog.dir == 0:
      cog.vx -= permilScale(cog.vx, IdleDragNum)
      cog.vy -= permilScale(cog.vy, IdleDragNum)
    else:
      let
        u = DirVecQ12[cog.dir]
        wantX = q12Scale(cap, u.x)
        wantY = q12Scale(cap, u.y)
        stepAccel = Accel div Substeps
      var dx = wantX - cog.vx
      var dy = wantY - cog.vy
      let d = distI(dx, dy)
      if d <= stepAccel:
        cog.vx = wantX
        cog.vy = wantY
      else:
        let n = unitQ12(dx, dy)
        cog.vx += q12Scale(stepAccel, n.x)
        cog.vy += q12Scale(stepAccel, n.y)
    capSpeed(cog.vx, cog.vy, cap)
    let
      stepX = cog.vx div Substeps
      stepY = cog.vy div Substeps
    cog.x += stepX
    cog.y += stepY
    cog.distanceUm += int64(distI(stepX, stepY))
    sim.cogs[i] = cog
  discard actions

proc integrateBall(sim: var SimServer) =
  if sim.ball.dead:
    return
  if sim.ball.controller >= 0:
    return                       ## carried; carryBall places it.
  sim.ball.vx -= permilScale(sim.ball.vx, BallDragNum) div Substeps
  sim.ball.vy -= permilScale(sim.ball.vy, BallDragNum) div Substeps
  capSpeed(sim.ball.vx, sim.ball.vy, BallMaxSpeed)
  sim.ball.x += sim.ball.vx div Substeps
  sim.ball.y += sim.ball.vy div Substeps
  if sim.ball.z > 0 or sim.ball.vz != 0:
    sim.ball.z += sim.ball.vz div Substeps
    sim.ball.vz -= Gravity div Substeps
    if sim.ball.z <= 0:
      sim.ball.z = 0
      sim.ball.vz = 0

proc carryBall(sim: var SimServer) =
  ## A cog in possession carries the ball at a dribble offset ahead of its
  ## velocity (or its held direction when it is standing still).
  let index = int(sim.ball.controller)
  if index < 0 or sim.ball.dead:
    return
  let cog = sim.cogs[index]
  var u = unitQ12(cog.vx, cog.vy)
  if u.d == 0:
    let d = if cog.dir >= 1 and cog.dir <= 8: cog.dir else: 3'i32
    u = (DirVecQ12[d].x, DirVecQ12[d].y, 0'i32)
  let offset =
    if cog.dribbling: DribbleOffsetOn else: DribbleOffsetOff
  sim.ball.x = cog.x + q12Scale(offset, u.x)
  sim.ball.y = cog.y + q12Scale(offset, u.y)
  sim.ball.vx = cog.vx
  sim.ball.vy = cog.vy
  sim.ball.z = 0
  sim.ball.vz = 0

proc resolveCogPairs(sim: var SimServer) =
  const Span = CogRadius + CogRadius
  for a in 0 ..< CogCount - 1:
    for b in a + 1 ..< CogCount:
      let
        dx = sim.cogs[b].x - sim.cogs[a].x
        dy = sim.cogs[b].y - sim.cogs[a].y
        u = unitQ12(dx, dy)
      if u.d >= Span:
        continue
      let
        pen = Span - u.d
        half = pen div 2
        sx = q12Scale(half, u.x)
        sy = q12Scale(half, u.y)
      sim.cogs[a].x -= sx
      sim.cogs[a].y -= sy
      sim.cogs[b].x += sx
      sim.cogs[b].y += sy
      let rel = int32((int64(sim.cogs[b].vx - sim.cogs[a].vx) * int64(u.x) +
        int64(sim.cogs[b].vy - sim.cogs[a].vy) * int64(u.y)) div 4096)
      if rel >= 0:
        continue
      # Equal masses: each body takes half of (1 + e) * (-rel).
      let j = pctScale(-rel, 100 + CogRestitutionPct) div 2
      let
        jx = q12Scale(j, u.x)
        jy = q12Scale(j, u.y)
      sim.cogs[a].vx -= jx
      sim.cogs[a].vy -= jy
      sim.cogs[b].vx += jx
      sim.cogs[b].vy += jy

proc clampCogs(sim: var SimServer) =
  for i in 0 ..< CogCount:
    var cog = sim.cogs[i]
    if cog.x < BoardXMin:
      cog.x = BoardXMin
      if cog.vx < 0: cog.vx = 0
    elif cog.x > BoardXMax:
      cog.x = BoardXMax
      if cog.vx > 0: cog.vx = 0
    if cog.y < BoardYMin:
      cog.y = BoardYMin
      if cog.vy < 0: cog.vy = 0
    elif cog.y > BoardYMax:
      cog.y = BoardYMax
      if cog.vy > 0: cog.vy = 0
    sim.cogs[i] = cog

proc knockBallLoose(sim: var SimServer, byIndex: int, dirX, dirY: int32) =
  sim.ball.controller = -1
  sim.ball.vx = q12Scale(TackleKnockSpeed, dirX)
  sim.ball.vy = q12Scale(TackleKnockSpeed, dirY)
  sim.ball.z = 0
  sim.ball.vz = 0
  discard byIndex

proc resolveSlides(sim: var SimServer) =
  ## Slide volumes vs the ball, then vs opponents, in cog index order.
  for i in 0 ..< CogCount:
    if sim.cogs[i].slideTicks <= 0:
      continue
    let team = teamOfCog(i)
    if not sim.ball.dead:
      let d = distI(sim.ball.x - sim.cogs[i].x, sim.ball.y - sim.cogs[i].y)
      if d <= SlideRadius + BallRadius and sim.ball.z <= GroundZ:
        sim.cogs[i].slideTouchedBall = true
        if sim.ball.controller != int32(i):
          if sim.ball.controller >= 0:
            inc sim.cogStats[i].tackles
            inc sim.teamStats[team].tackles
            sim.emitEvent(Tackle, source = i,
              target = int(sim.ball.controller), team = ord(team),
              x = sim.ball.x, y = sim.ball.y)
          sim.knockBallLoose(i, sim.cogs[i].slideDirX, sim.cogs[i].slideDirY)
          sim.recordTouch(i)
        continue
    if sim.cogs[i].slideTouchedBall:
      continue
    for j in 0 ..< CogCount:
      if teamOfCog(j) == team:
        continue
      let d = distI(sim.cogs[j].x - sim.cogs[i].x,
        sim.cogs[j].y - sim.cogs[i].y)
      if d > SlideRadius + CogRadius:
        continue
      # A slide that reaches an opponent without having touched the ball on
      # any tick of this slide is a FOUL.
      inc sim.cogStats[i].fouls
      sim.cogs[i].slideTicks = 0
      sim.cogs[i].groundedTicks = GroundedAfterFoul
      sim.cogs[i].vx = 0
      sim.cogs[i].vy = 0
      let spot = freeKickSpot(other(team), sim.cogs[j].x, sim.cogs[j].y)
      sim.emitEvent(Foul, source = i, target = j, team = ord(team),
        x = spot.x, y = spot.y)
      sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "foul",
        team: int32(ord(team)),
        text: cogId(i) & " slides in — foul, free kick " &
          teamPrefix(other(team)))
      sim.beginRestart(rkFreeKick, int32(ord(other(team))), int32(j),
        spot.x, spot.y)
      return

proc resolveBallCogs(sim: var SimServer) =
  ## Control, deflection, or (keeper, in its own area) catch/parry. An airborne
  ## ball ignores cogs until it is back near the ground.
  if sim.ball.dead or sim.ball.controller >= 0:
    return
  if sim.ball.z > GroundZ:
    return
  var
    best = -1
    bestD = high(int32)
  for i in 0 ..< CogCount:
    if sim.cogs[i].groundedTicks > 0 or sim.cogs[i].slideTicks > 0:
      continue
    let d = distI(sim.ball.x - sim.cogs[i].x, sim.ball.y - sim.cogs[i].y)
    if d < bestD:
      bestD = d
      best = i
  if best < 0:
    return
  let team = teamOfCog(best)
  # The keeper first: inside its own area it catches or parries.
  if isKeeper(best) and inPenaltyArea(team, sim.cogs[best].x,
      sim.cogs[best].y):
    let d = distI(sim.ball.x - sim.cogs[best].x, sim.ball.y - sim.cogs[best].y)
    if d <= KeeperCatchRadius:
      let speed = speedOf(sim.ball.vx, sim.ball.vy)
      if speed <= KeeperCatchSpeed:
        inc sim.teamStats[team].saves
        sim.recordTouch(best)
        sim.emitEvent(Save, source = best, team = ord(team),
          x = sim.ball.x, y = sim.ball.y, content = "catch")
        sim.arcs.add ArcFx(x0: sim.ball.x, y0: sim.ball.y,
          x1: sim.ball.x, y1: sim.ball.y, tick: int32(sim.tickCount),
          team: int32(ord(team)), kind: 2)
        sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "save",
          team: int32(ord(team)), text: cogId(best) & " gathers it — goal kick")
        let spot = sixYardCentre(team)
        sim.beginRestart(rkGoalKick, int32(ord(team)), int32(best),
          spot.x, spot.y)
        return
      else:
        let u = unitQ12(sim.ball.x - sim.cogs[best].x,
          sim.ball.y - sim.cogs[best].y)
        var vx = pctScale(q12Scale(speed, u.x), KeeperParryPct)
        var vy = pctScale(q12Scale(speed, u.y), KeeperParryPct)
        capSpeed(vx, vy, KeeperParryCap)
        sim.ball.vx = vx
        sim.ball.vy = vy
        inc sim.teamStats[team].saves
        sim.emitEvent(Save, source = best, team = ord(team),
          x = sim.ball.x, y = sim.ball.y, content = "parry")
        sim.arcs.add ArcFx(x0: sim.ball.x, y0: sim.ball.y,
          x1: sim.ball.x, y1: sim.ball.y, tick: int32(sim.tickCount),
          team: int32(ord(team)), kind: 2)
        sim.recordTouch(best)
        return
  if bestD > ControlRadius:
    return
  let speed = speedOf(sim.ball.vx, sim.ball.vy)
  if speed <= ControlSpeed:
    sim.ball.controller = int32(best)
    sim.recordTouch(best)
    sim.carryBall()
  else:
    let u = unitQ12(sim.ball.x - sim.cogs[best].x,
      sim.ball.y - sim.cogs[best].y)
    let vn = int32((int64(sim.ball.vx) * int64(u.x) +
      int64(sim.ball.vy) * int64(u.y)) div 4096)
    if vn < 0:
      let k = pctScale(-vn, 100 + DeflectPct)
      sim.ball.vx += q12Scale(k, u.x)
      sim.ball.vy += q12Scale(k, u.y)
      capSpeed(sim.ball.vx, sim.ball.vy, BallMaxSpeed)
    sim.recordTouch(best)

proc resolveBallPosts(sim: var SimServer) =
  if sim.ball.dead or sim.ball.controller >= 0:
    return
  const Span = PostRadius + BallRadius
  for post in Posts:
    let
      dx = sim.ball.x - post.x
      dy = sim.ball.y - post.y
      u = unitQ12(dx, dy)
    if u.d >= Span:
      continue
    sim.ball.x = post.x + q12Scale(Span, u.x)
    sim.ball.y = post.y + q12Scale(Span, u.y)
    let vn = int32((int64(sim.ball.vx) * int64(u.x) +
      int64(sim.ball.vy) * int64(u.y)) div 4096)
    if vn < 0:
      let k = pctScale(-vn, 100 + PostRestitutionPct)
      sim.ball.vx += q12Scale(k, u.x)
      sim.ball.vy += q12Scale(k, u.y)
    sim.arcs.add ArcFx(x0: sim.ball.x, y0: sim.ball.y,
      x1: sim.ball.x, y1: sim.ball.y, tick: int32(sim.tickCount),
      team: -1, kind: 2)
    sim.emitEvent(Post, x = sim.ball.x, y = sim.ball.y)

proc resolveBallNetting(sim: var SimServer) =
  ## Behind a goal line inside the mouth band the ball is in the net: keep it
  ## inside the board box so nothing can leave the world.
  if sim.ball.dead:
    return
  if sim.ball.x < BoardXMin:
    sim.ball.x = BoardXMin
    sim.ball.vx = 0
  elif sim.ball.x > BoardXMax:
    sim.ball.x = BoardXMax
    sim.ball.vx = 0
  if sim.ball.y < BoardYMin:
    sim.ball.y = BoardYMin
    sim.ball.vy = 0
  elif sim.ball.y > BoardYMax:
    sim.ball.y = BoardYMax
    sim.ball.vy = 0

proc scoreGoal(sim: var SimServer, scorer: Team) =
  inc sim.teamStats[scorer].goals
  let
    speed = speedOf(sim.ball.vx, sim.ball.vy)
    by = int(sim.lastTouch.cog)
  var assist = -1
  if sim.prevTouch.cog >= 0 and
      sim.prevTouch.team == int32(ord(scorer)) and
      sim.prevTouch.cog != sim.lastTouch.cog and
      int32(sim.tickCount) - sim.prevTouch.tick <= AssistWindowTicks:
    assist = int(sim.prevTouch.cog)
  if by >= 0 and teamOfCog(by) == scorer:
    inc sim.cogStats[by].goals
  if assist >= 0:
    inc sim.cogStats[assist].assists
  sim.goalFx.add GoalFx(tick: int32(sim.tickCount), team: int32(ord(scorer)))
  sim.lastGoalTick = int32(sim.tickCount)
  sim.lastGoalTeam = int32(ord(scorer))
  sim.lastGoalBy = int32(by)
  sim.lastGoalAssist = int32(assist)
  sim.lastGoalSpeed = speed
  sim.emitEvent(Goal, source = by, target = assist, team = ord(scorer),
    amount = sim.goals(scorer), x = sim.ball.x, y = sim.ball.y, speed = speed)
  sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "goal",
    team: int32(ord(scorer)),
    text: "GOAL " & teamPrefix(scorer) & " — " &
      (if by >= 0: cogId(by) else: "own goal") &
      (if assist >= 0: " (assist " & cogId(assist) & ")" else: ""))
  sim.logGameEvent("goal for " & teamText(scorer) & ": " &
    $sim.goals(Red) & "-" & $sim.goals(Blue))
  # Kickoff by the CONCEDING team, from the centre spot.
  let conceding = other(scorer)
  let taker = cogOfShirt(conceding, 10)
  sim.placeCog(taker,
    CentreX - RestartTakerOffset * attackDir(conceding), CentreY)
  sim.beginRestart(rkKickoff, int32(ord(conceding)), int32(taker),
    CentreX, CentreY)

proc handleOutOfPlay(sim: var SimServer): bool =
  ## The restart table. Returns true when the ball left the field of play.
  if sim.ball.dead:
    return false
  if inPitch(sim.ball.x, sim.ball.y):
    return false
  let
    lastTeam =
      if sim.lastTouch.team >= 0: Team(sim.lastTouch.team and 1) else: Red
    outX = sim.ball.x
    outY = sim.ball.y
  sim.emitEvent(Out, team = int(sim.lastTouch.team), x = outX, y = outY)
  if outY < PitchYMin or outY > PitchYMax:
    # Touchline: throw-in to the team that did NOT touch it last.
    let
      awarded = other(lastTeam)
      sx = clamp(outX, PitchXMin, PitchXMax)
      sy = if outY < PitchYMin: PitchYMin else: PitchYMax
    var
      taker = firstCogOf(awarded) + 1
      bestD = high(int32)
    for j in 0 ..< CogsPerTeam:
      let i = firstCogOf(awarded) + j
      if isKeeper(i):
        continue
      let d = distI(sim.cogs[i].x - sx, sim.cogs[i].y - sy)
      if d < bestD:
        bestD = d
        taker = i
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "out",
      team: int32(ord(awarded)),
      text: "throw-in, " & teamPrefix(awarded))
    sim.beginRestart(rkThrowIn, int32(ord(awarded)), int32(taker), sx, sy)
    return true
  # A goal line, outside the mouth (a goal is tested before this).
  let defending = if outX <= PitchXMin: Red else: Blue
  if lastTeam == defending:
    # Corner to the attacking team.
    let
      awarded = other(defending)
      spot = cornerArc(outX, outY)
    var
      taker = firstCogOf(awarded) + 1
      bestD = high(int32)
    for j in 0 ..< CogsPerTeam:
      let i = firstCogOf(awarded) + j
      if isKeeper(i):
        continue
      let d = distI(sim.cogs[i].x - spot.x, sim.cogs[i].y - spot.y)
      if d < bestD:
        bestD = d
        taker = i
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "out",
      team: int32(ord(awarded)), text: "corner, " & teamPrefix(awarded))
    sim.beginRestart(rkCorner, int32(ord(awarded)), int32(taker),
      spot.x, spot.y)
  else:
    # Goal kick to the defending keeper.
    let spot = sixYardCorner(defending, outY)
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "out",
      team: int32(ord(defending)),
      text: "goal kick, " & teamPrefix(defending))
    sim.beginRestart(rkGoalKick, int32(ord(defending)),
      int32(sim.keeperOf(defending)), spot.x, spot.y)
  true

proc physicsGuardTripped(sim: SimServer): bool =
  ## The `sim_fault` guard: any body outside the board box, a non-representable
  ## velocity, or a ball with no defined phase.
  if not onBoard(sim.ball.x, sim.ball.y):
    return true
  if speedOf(sim.ball.vx, sim.ball.vy) > 2 * BallMaxSpeed:
    return true
  if sim.ball.z < 0 or sim.ball.z > 100_000_000'i32:
    return true
  if sim.ball.controller < -1 or sim.ball.controller >= CogCount:
    return true
  for cog in sim.cogs:
    if not onBoard(cog.x, cog.y):
      return true
    if speedOf(cog.vx, cog.vy) > 2 * SprintSpeed:
      return true
  false

proc runSubsteps(sim: var SimServer, actions: openArray[uint8]): bool =
  ## Four substeps of 1/96 s. Returns true when a goal abandoned the tick.
  for _ in 0 ..< Substeps:
    sim.integrateCogs(actions)
    sim.integrateBall()
    sim.resolveCogPairs()
    sim.clampCogs()
    sim.resolveSlides()
    if sim.ball.dead:
      return false                ## a foul restarted play mid-substep.
    sim.resolveBallCogs()
    sim.carryBall()
    sim.resolveBallPosts()
    sim.resolveBallNetting()
    let scorer = goalScoredBy(sim.ball.x, sim.ball.y)
    if scorer >= 0 and not sim.ball.dead:
      sim.scoreGoal(Team(scorer and 1))
      return true
    if sim.handleOutOfPlay():
      return false
  false

# --------------------------------------------------------------------------
# The step loop
# --------------------------------------------------------------------------

proc trimFx(sim: var SimServer) =
  ## Cosmetic pools are bounded so a long match cannot grow the wire without
  ## limit. None of this is in gameHash.
  const TrailLen = 40
  while sim.trail.len > TrailLen:
    sim.trail.delete(0)
  while sim.arcs.len > 24:
    sim.arcs.delete(0)
  while sim.goalFx.len > 8:
    sim.goalFx.delete(0)
  while sim.feed.len > 64:
    sim.feed.delete(0)

proc applyModes(sim: var SimServer, actions: openArray[uint8]) =
  ## Step 5: the sprint bit, the dribble toggles, stamina, and slide starts.
  for i in 0 ..< CogCount:
    let action = if i < actions.len: actions[i] else: 0'u8
    var cog = sim.cogs[i]
    if cog.groundedTicks > 0 or cog.slideTicks > 0:
      cog.stamina = min(StaminaMax, cog.stamina + StaminaRecover)
      sim.cogs[i] = cog
      continue
    cog.dir = actionDir(action)
    let wantSprint = actionSprint(action) and cog.stamina > ExhaustedStamina
    cog.sprinting = wantSprint
    case actionCode(action)
    of 6: cog.dribbling = true
    of 7: cog.dribbling = false
    else: discard
    if cog.sprinting:
      cog.stamina = max(0'i32, cog.stamina - StaminaDrain)
    else:
      cog.stamina = min(StaminaMax, cog.stamina + StaminaRecover)
    sim.cogs[i] = cog
  for i in 0 ..< CogCount:
    let action = if i < actions.len: actions[i] else: 0'u8
    if actionCode(action) != 5:
      continue
    if sim.cogs[i].slideTicks > 0 or sim.cogs[i].groundedTicks > 0:
      continue
    let d = if sim.cogs[i].dir >= 1 and sim.cogs[i].dir <= 8: sim.cogs[i].dir
            else: dirOfVector(sim.cogs[i].vx, sim.cogs[i].vy)
    if d == 0:
      continue
    sim.cogs[i].slideTicks = SlideTicks
    sim.cogs[i].slideTouchedBall = false
    sim.cogs[i].slideDirX = DirVecQ12[d].x
    sim.cogs[i].slideDirY = DirVecQ12[d].y
    sim.cogs[i].vx = q12Scale(SlideSpeed, DirVecQ12[d].x)
    sim.cogs[i].vy = q12Scale(SlideSpeed, DirVecQ12[d].y)
    sim.cogs[i].dribbling = false
    if sim.ball.controller == int32(i):
      sim.knockBallLoose(i, sim.cogs[i].slideDirX, sim.cogs[i].slideDirY)
    sim.emitEvent(Tackle, source = i, team = ord(teamOfCog(i)),
      x = sim.cogs[i].x, y = sim.cogs[i].y, content = "slide_start")

proc stepRestart(sim: var SimServer) =
  ## One tick of a dead-ball phase: the ball sits on the spot, the taker is
  ## snapped behind it and every opponent inside RestartClearRadius is pushed
  ## radially out to exactly that radius. Everyone else moves normally.
  let
    sx = sim.restartX
    sy = sim.restartY
  sim.ball.x = sx
  sim.ball.y = sy
  sim.ball.vx = 0
  sim.ball.vy = 0
  sim.ball.z = 0
  sim.ball.vz = 0
  sim.ball.controller = -1
  if sim.restartTaker >= 0:
    let
      taker = int(sim.restartTaker)
      team = teamOfCog(taker)
      dir = attackDir(team)
    sim.cogs[taker].x = clamp(sx - RestartTakerOffset * dir,
      BoardXMin, BoardXMax)
    sim.cogs[taker].y = clamp(sy, BoardYMin, BoardYMax)
    sim.cogs[taker].vx = 0
    sim.cogs[taker].vy = 0
    sim.cogs[taker].slideTicks = 0
  for i in 0 ..< CogCount:
    if sim.restartTeam >= 0 and int32(ord(teamOfCog(i))) == sim.restartTeam:
      continue
    if sim.restartTaker == int32(i):
      continue
    let
      dx = sim.cogs[i].x - sx
      dy = sim.cogs[i].y - sy
      u = unitQ12(dx, dy)
    if u.d < RestartClearRadius:
      sim.cogs[i].x = clamp(sx + q12Scale(RestartClearRadius, u.x),
        BoardXMin, BoardXMax)
      sim.cogs[i].y = clamp(sy + q12Scale(RestartClearRadius, u.y),
        BoardYMin, BoardYMax)
      sim.cogs[i].vx = 0
      sim.cogs[i].vy = 0
  dec sim.restartTicks
  if sim.restartTicks <= 0:
    sim.ball.dead = false
    sim.restartTicks = 0
    if sim.restartTaker >= 0:
      sim.ball.controller = sim.restartTaker
      sim.recordTouch(int(sim.restartTaker))
      sim.carryBall()
    sim.lastRestartTick = int32(sim.tickCount)
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "restart",
      team: sim.restartTeam,
      text: restartText(sim.restartKind) &
        (if sim.restartTaker >= 0: " — " & cogId(int(sim.restartTaker))
         else: ""))
    sim.restartKind = rkNone

proc halfTime(sim: var SimServer) =
  sim.half = 2
  sim.lastHalfTimeTick = int32(sim.tickCount)
  sim.emitEvent(HalfTime, amount = 2, x = CentreX, y = CentreY)
  sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "halftime",
    team: -1, text: "HALF TIME")
  sim.logGameEvent("half time: " & $sim.goals(Red) & "-" & $sim.goals(Blue))
  # The team that did NOT kick off at tick 0 kicks off the second half.
  let first = int32(sim.config.seed and 1)
  sim.formationReset(int32(1 - int(first)), 250'i32)

proc stepPlaying(sim: var SimServer, actions: openArray[uint8]) =
  # 2. Timers.
  for i in 0 ..< CogCount:
    var cog = sim.cogs[i]
    if cog.slideTicks > 0:
      dec cog.slideTicks
      if cog.slideTicks == 0:
        cog.groundedTicks = max(cog.groundedTicks, GroundedAfterSlide)
        cog.vx = 0
        cog.vy = 0
    elif cog.groundedTicks > 0:
      dec cog.groundedTicks
    if cog.passCooldown > 0: dec cog.passCooldown
    if cog.shotCooldown > 0: dec cog.shotCooldown
    sim.cogs[i] = cog

  if sim.restartTicks > 0:
    # A restart still integrates the non-taker cogs so they spread and mark.
    sim.applyModes(actions)
    sim.integrateCogs(actions)
    sim.resolveCogPairs()
    sim.clampCogs()
    sim.stepRestart()
  else:
    # 5. Modes.
    sim.applyModes(actions)
    # 6. On-ball actions, in cog index order, for the controller only.
    let holder = int(sim.ball.controller)
    if holder >= 0:
      let action = if holder < actions.len: actions[holder] else: 0'u8
      let code = actionCode(action)
      if code in 1'i32 .. 4'i32:
        sim.releaseOnBall(holder, code, actionDir(action))
    # 7. Four substeps (goal / out-of-play tests inside).
    discard sim.runSubsteps(actions)

  # 9. Possession bookkeeping.
  if sim.ball.controller >= 0:
    inc sim.teamStats[teamOfCog(int(sim.ball.controller))].possessionTicks
  elif sim.lastTouch.team >= 0:
    inc sim.teamStats[Team(sim.lastTouch.team and 1)].possessionTicks

  # 10. Stalemate counter and, at the threshold, the neutral drop.
  if sim.restartTicks <= 0:
    let
      dx = sim.ball.x - sim.anchorX
      dy = sim.ball.y - sim.anchorY
    if abs(dx) <= StalemateBox and abs(dy) <= StalemateBox and
        sim.lastTouch.tick != int32(sim.tickCount):
      inc sim.stalemateTicks
    else:
      sim.anchorX = sim.ball.x
      sim.anchorY = sim.ball.y
      sim.stalemateTicks = 0
    if sim.stalemateTicks >= int32(sim.config.stalemateTicks):
      sim.neutralDrop()

  if sim.physicsGuardTripped():
    sim.finishGame(reasonFault, erSimFault)
    return

  # Cosmetics (never hashed).
  sim.trail.add TrailPoint(x: sim.ball.x, y: sim.ball.y, z: sim.ball.z,
    tick: int32(sim.tickCount), team: sim.lastTouch.team)
  sim.trimFx()

  # 12. Boundaries.
  let elapsed = sim.tickCount - sim.gameStartTick
  if sim.half == 1 and sim.config.halfTicks > 0 and
      elapsed + 1 >= sim.config.halfTicks and
      elapsed + 1 < sim.config.maxTicks:
    sim.halfTime()
    return
  if (elapsed + 1) mod sim.turnTicks() == 0:
    sim.emitEvent(DirectiveEvent, amount = sim.currentTurn(), content = "turn_end")
    if abs(sim.goalDiff(Red)) >= sim.config.mercyGoalDiff:
      sim.finishGame(reasonComplete, erMercy)
      return
  if elapsed + 1 >= sim.config.maxTicks:
    sim.finishGame(reasonComplete, erFullTime)

const ZeroActions: array[CogCount, uint8] = default(array[CogCount, uint8])

proc step*(
  sim: var SimServer,
  actions: openArray[uint8],
  prevActions: openArray[uint8]
) =
  ## Advances the sim by one tick. `prevActions` is accepted for parity with
  ## ctf's signature (the replay path builds both); grf-football's action byte
  ## is level-triggered for the direction and sprint bits and edge-triggered
  ## only through the one-shot codes, which are cleared by resolution, so
  ## nothing here reads it.
  discard prevActions
  case sim.phase
  of Lobby:
    if sim.players.len < sim.config.minPlayers:
      inc sim.lobbyWaitTimer
      sim.startWaitTimer = 0
      sim.logLobbyWaiting()
    else:
      sim.logLobbyWaiting()
      if sim.startWaitTimer <= 0:
        sim.startWaitTimer = max(1, sim.config.startWaitTicks)
      sim.logLobbyCountdown()
      dec sim.startWaitTimer
      if sim.startWaitTimer <= 0:
        sim.startGame()
  of Playing:
    if actions.len >= CogCount:
      sim.stepPlaying(actions)
    else:
      sim.stepPlaying(ZeroActions)
  of GameOver:
    if sim.gameOverTimer > 0:
      dec sim.gameOverTimer
  inc sim.tickCount

proc wallClockStop*(sim: var SimServer) =
  ## The engine's hard stop. The score at this instant stands, the replay is
  ## complete up to this tick, and the game-over frame is written.
  if sim.phase == Playing:
    sim.finishGame(reasonDeadline, erWallClock)

proc hostErrorStop*(sim: var SimServer) =
  if sim.phase != GameOver:
    sim.finishGame(reasonFault, erHostError)
