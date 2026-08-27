## The control layer: the ONE deterministic, integer-only function that turns a
## seat's order into that shirt's per-tick action byte.
##
## Both LLM orders and scripted orders are compiled by THIS code, so the two
## policy kinds are strictly comparable and a scripted baseline is legal by
## construction. It is a pure function of `(sim state, order, cogIndex)`.
##
## It sits OUTSIDE the determinism boundary: the server records the bytes this
## produces into the replay, and the wasm viewer feeds those recorded bytes to
## the identical sim. Nothing here is re-run at playback, which is why the
## whole class of "the controller was reimplemented in the viewer and drifted"
## bugs is structurally impossible.
##
## No floating point: tests/test_determinism.nim greps this file.

import sim, builtin_ai

const
  TargetBiasNum* = 3'i32     ## p* = (p*·3 + target) div 4 — a 25 % bias.
  PressLeadTicks* = 8'i32
  ShadowLeadTicks* = 12'i32
  MakeRunAhead* = 12_000_000'i32
  SwitchPlayY* = 18_000_000'i32
  SprintCarryRadius* = 4_000_000'i32
  DribbleOnRadius* = 5_000_000'i32
  ShootMaxRange* = 30_000_000'i32

proc compileAction*(
  sim: SimServer,
  index: int,
  order: CogOrder
): uint8 =
  ## One seated shirt's action byte for one tick.
  let
    team = teamOfCog(index)
    dir = attackDir(team)
    gx = targetGoalX(team)
    ownX = ownGoalX(team)
    anchor = sim.translatedAnchor(index)

  # ---- 1. the steering point ------------------------------------------------
  var
    px = anchor.x
    py = anchor.y
  case order.intent
  of inPress:
    if sim.ball.controller >= 0:
      let o = int(sim.ball.controller)
      px = sim.cogs[o].x + int32(int64(sim.cogs[o].vx) * int64(PressLeadTicks))
      py = sim.cogs[o].y + int32(int64(sim.cogs[o].vy) * int64(PressLeadTicks))
    else:
      let p = sim.interceptPoint(index)
      px = p.x
      py = p.y
  of inHoldShape:
    px = int32((int64(order.targetX) + int64(anchor.x)) div 2)
    py = int32((int64(order.targetY) + int64(anchor.y)) div 2)
  of inMakeRun:
    px = clamp(sim.ball.x + MakeRunAhead * dir, PitchXMin, PitchXMax)
    py = clamp(order.targetY, PitchYMin, PitchYMax)
  of inSupport:
    let s = sim.supportPoint(index)
    px = s.x
    py = s.y
  of inDropDeep:
    px = int32((int64(sim.ball.x) + int64(ownX)) div 2)
    py = int32((int64(sim.ball.y) + int64(CentreY)) div 2)
  of inCarry:
    px = gx
    py = CentreY
  of inSwitchPlay:
    px = anchor.x
    py = if sim.ball.y >= CentreY: CentreY - SwitchPlayY
         else: CentreY + SwitchPlayY
  of inShadow:
    let o = sim.nearestOpponent(index)
    if o >= 0:
      px = sim.cogs[o].x + int32(int64(sim.cogs[o].vx) * int64(ShadowLeadTicks))
      py = sim.cogs[o].y + int32(int64(sim.cogs[o].vy) * int64(ShadowLeadTicks))

  if order.intent != inHoldShape:
    # Every intent except hold_shape blends the order target as a 25 % bias.
    px = int32((int64(px) * int64(TargetBiasNum) + int64(order.targetX)) div 4)
    py = int32((int64(py) * int64(TargetBiasNum) + int64(order.targetY)) div 4)

  # Override, always: if the ball is loose and this cog is the closest of its
  # team to it, p* becomes the interception point regardless of intent. A
  # footballer who can win the ball, wins it.
  var chasing = false
  if sim.ballIsLoose() and
      sim.nearestOfTeamToBall(team) == index:
    let p = sim.interceptPoint(index)
    px = p.x
    py = p.y
    chasing = true

  px = clamp(px, PitchXMin, PitchXMax)
  py = clamp(py, PitchYMin, PitchYMax)

  # ---- 3. the sprint bit ----------------------------------------------------
  var sprint = false
  case order.sprint
  of spAlways: sprint = sim.cogs[index].stamina > 100
  of spNever: sprint = false
  of spAuto:
    sprint =
      (chasing and sim.distToBall(index) > 6_000_000'i32) or
      order.intent == inMakeRun or
      (sim.ball.controller == int32(index) and
        sim.nearestOpponentDist(index) < SprintCarryRadius)

  # ---- 4. the on-ball code --------------------------------------------------
  var
    code = 0'i32
    codeDir = 0'i32
  if sim.ball.controller == int32(index):
    let safe = sim.safeOnBall(index)
    case order.onBall
    of obShoot:
      let goalDist = distI(gx - sim.cogs[index].x, CentreY - sim.cogs[index].y)
      if sim.cogs[index].shotCooldown == 0 and goalDist <= ShootMaxRange and
          sim.shootingLaneClear(index):
        code = 4
        codeDir = dirOfVector(gx - sim.cogs[index].x,
          CentreY - sim.cogs[index].y)
      else:
        code = safe.code
        codeDir = safe.dir
    of obPassShort, obPassLong, obPassHigh:
      let
        wanted = (case order.onBall
          of obPassShort: 1'i32
          of obPassLong: 2'i32
          else: 3'i32)
        maxRange = (case order.onBall
          of obPassShort: ShortPassRange
          of obPassLong: LongPassRange
          else: HighPassRange)
      # `pass_to` never reaches the sim — a directive is not in the action log.
      # The receiver is chosen HERE and encoded as the DIRECTION NIBBLE, which
      # is the cone `sim.bestReceiver` searches, so the recorded byte alone
      # reproduces the same pass on re-simulation.
      var receiver = -1
      if order.passTo >= 0 and int(order.passTo) != index and
          teamOfCog(int(order.passTo)) == team:
        let d = distI(sim.cogs[int(order.passTo)].x - sim.cogs[index].x,
          sim.cogs[int(order.passTo)].y - sim.cogs[index].y)
        if d > 0 and d <= maxRange:
          receiver = int(order.passTo)
      if receiver < 0:
        receiver = sim.bestPassMate(index, maxRange)
      if receiver >= 0 and sim.cogs[index].passCooldown == 0:
        code = wanted
        codeDir = dirOfVector(sim.cogs[receiver].x - sim.cogs[index].x,
          sim.cogs[receiver].y - sim.cogs[index].y)
      else:
        code = safe.code
        codeDir = safe.dir
    of obDribble:
      if not sim.cogs[index].dribbling:
        code = 6
      px = gx
      py = CentreY
    of obHold:
      let o = sim.nearestOpponent(index)
      if o >= 0:
        # Shield: face away from the nearest opponent.
        px = clamp(sim.cogs[index].x * 2 - sim.cogs[o].x,
          PitchXMin, PitchXMax)
        py = clamp(sim.cogs[index].y * 2 - sim.cogs[o].y,
          PitchYMin, PitchYMax)
    # ---- 6. dribble mode is always in a defined state ----------------------
    if code == 0:
      let close = sim.nearestOpponentDist(index) < DribbleOnRadius
      if close and not sim.cogs[index].dribbling: code = 6
      elif not close and sim.cogs[index].dribbling: code = 7
  else:
    # ---- 5. the tackle ------------------------------------------------------
    if order.tackle != tkNever and sim.wantsTackle(index):
      code = 5
    elif sim.cogs[index].dribbling:
      code = 7

  sim.steerAction(index, px, py, sprint, code, codeDir)

proc compileActions*(
  sim: SimServer,
  directives: array[SeatCount, Directive]
): array[CogCount, uint8] =
  ## The 22 action bytes for one tick, in cog index order (`RED-1..11` then
  ## `BLUE-1..11`). Every cog always has a byte, so no failure mode can leave
  ## one unactuated: a seated shirt gets its seat's order compiled here, and
  ## every other shirt gets the built-in AI's byte.
  ##
  ## During a restart the taker's byte is forced to `0x00` and every other
  ## cog's ACTION CODE is forced to 0 — they may still move and mark, but
  ## nobody may pass, shoot, slide or toggle a mode while the ball is dead.
  if sim.phase != Playing:
    return
  let restarting = sim.restartTicks > 0
  for i in 0 ..< CogCount:
    var action: uint8
    let seat = sim.seatOfCog(i)
    if seat >= 0:
      action = sim.compileAction(i, directives[seat].cog)
    else:
      action = sim.builtinAction(i)
    if restarting:
      if sim.restartTaker == int32(i):
        action = 0'u8
      else:
        action = encodeAction(actionDir(action), 0, actionSprint(action))
    result[i] = action
