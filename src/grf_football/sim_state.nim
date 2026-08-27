## Sim-state services shared by the roster machinery and the gameplay core:
## lobby status, game-event logging, the replay hash (gameHash / mixHash), and
## the tier-2 event sink (emitEvent). Stage 5 of ctf's sim split, kept.
##
## `gameHash` is the determinism contract with the wasm viewer: it mixes the
## tick, the phase, the verdict, the score, the restart state and every body's
## position, velocity, direction, modes, stamina and timers — and NOTHING else.
## Directives, notes, FX, trails and the feed never enter it, exactly as ctf
## keeps damagePops and skin out.

import
  std/strutils,
  sim_types

proc lobbyIsStarting*(sim: SimServer): bool =
  sim.players.len >= sim.config.minPlayers

proc lobbyStartTicksRemaining*(sim: SimServer): int =
  if not sim.lobbyIsStarting() or sim.config.startWaitTicks <= 0:
    return 0
  if sim.startWaitTimer > 0: sim.startWaitTimer else: sim.config.startWaitTicks

proc lobbyStartSecondsRemaining*(sim: SimServer): int =
  let ticks = sim.lobbyStartTicksRemaining()
  if ticks <= 0:
    return 0
  max(1, (ticks + TargetFps - 1) div TargetFps)

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  ## True when a finite match has waited out `lobbyJoinTimeoutTicks` lobby
  ## ticks still short of `minPlayers`. The clock runs on LOBBY ticks, so the
  ## turf bake before the loop starts never eats the budget.
  sim.phase == Lobby and sim.config.lobbyJoinTimeoutTicks > 0 and
    sim.players.len < sim.config.minPlayers and
    sim.lobbyWaitTimer >= sim.config.lobbyJoinTimeoutTicks

proc logGameEvent*(sim: SimServer, text: string) =
  if sim.gameEventLoggingEnabled:
    echo text

proc logLobbyWaiting*(sim: var SimServer) =
  let
    needed = max(0, sim.config.minPlayers - sim.players.len)
    players = sim.players.len
  if players == sim.lastLobbyPlayersLogged and
      needed == sim.lastLobbyNeededLogged:
    return
  sim.lastLobbyPlayersLogged = players
  sim.lastLobbyNeededLogged = needed
  sim.lastLobbySecondsLogged = -1
  sim.logGameEvent("waiting for players: " & $players & "/" &
    $sim.config.minPlayers & ", need " & $needed & " more")

proc logLobbyCountdown*(sim: var SimServer) =
  let seconds = sim.lobbyStartSecondsRemaining()
  if seconds <= 0 or seconds == sim.lastLobbySecondsLogged:
    return
  sim.lastLobbySecondsLogged = seconds
  sim.logGameEvent("game starting in " & $seconds)

proc mixHash(hash: var uint64, value: uint64) {.inline.} =
  ## FNV-1a, ctf's mixer, unchanged.
  hash = hash xor value
  hash *= 1099511628211'u64

proc mixHashI32(hash: var uint64, value: int32) {.inline.} =
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashInt(hash: var uint64, value: int) {.inline.} =
  hash.mixHash(cast[uint64](int64(value)))

proc mixHashBool(hash: var uint64, value: bool) {.inline.} =
  hash.mixHashInt(ord(value))

proc gameHash*(sim: SimServer): uint64 =
  ## A deterministic hash of gameplay state. Written once per tick into the
  ## replay and re-derived by the wasm viewer; a single divergent bit surfaces
  ## at the tick it happens.
  result = 14695981039346656037'u64
  result.mixHashInt(sim.tickCount)
  result.mixHashInt(ord(sim.phase))
  result.mixHashInt(ord(sim.winner))
  result.mixHashBool(sim.isDraw)
  result.mixHashBool(sim.ended)
  result.mixHashInt(ord(sim.endReason))
  result.mixHashInt(ord(sim.endRule))
  result.mixHashInt(sim.gameOverTimer)
  result.mixHashInt(sim.gameStartTick)
  result.mixHashInt(sim.startWaitTimer)
  result.mixHashI32(sim.half)
  result.mixHashInt(ord(sim.restartKind))
  result.mixHashI32(sim.restartTeam)
  result.mixHashI32(sim.restartTaker)
  result.mixHashI32(sim.restartTicks)
  result.mixHashI32(sim.restartX)
  result.mixHashI32(sim.restartY)
  result.mixHashI32(sim.stalemateTicks)
  result.mixHashI32(sim.anchorX)
  result.mixHashI32(sim.anchorY)
  result.mixHashBool(sim.needsReregister)
  result.mixHashI32(sim.nextJoinOrder)
  # The RNG's own state is private to std/random; the DRAW COUNT stands in for
  # it, and it is the reason a drifted stream is caught on the tick it drifts.
  result.mixHashI32(sim.rngDraws)
  result.mixHashInt(sim.lobbyWaitTimer)
  # Every remaining field the step writes. These are all set INSIDE the step on
  # both sides of the native/wasm boundary, so hashing them costs nothing and
  # makes the chain say exactly which write diverged.
  result.mixHashI32(sim.lastGoalTick)
  result.mixHashI32(sim.lastGoalTeam)
  result.mixHashI32(sim.lastGoalBy)
  result.mixHashI32(sim.lastGoalAssist)
  result.mixHashI32(sim.lastGoalSpeed)
  result.mixHashI32(sim.lastDropTick)
  result.mixHashI32(sim.lastRestartTick)
  result.mixHashI32(sim.lastHalfTimeTick)
  # `trail`, `arcs` and `goalFx` are NOT mixed, not even by length. They are the
  # cosmetic pools, and the contract in this module's docstring, in the design
  # note's resolution step 11 and on the fields themselves (sim_types.nim:537-539
  # "never hashed") is that FX and trails never enter the chain. Their lengths
  # are deterministic, so hashing them was harmless and still wrong: it made the
  # chain say a divergence had happened in the hashed state when what had
  # actually changed was a celebration.
  result.mixHashI32(sim.ball.x)
  result.mixHashI32(sim.ball.y)
  result.mixHashI32(sim.ball.vx)
  result.mixHashI32(sim.ball.vy)
  result.mixHashI32(sim.ball.z)
  result.mixHashI32(sim.ball.vz)
  result.mixHashI32(sim.ball.controller)
  result.mixHashBool(sim.ball.dead)
  for cog in sim.cogs:
    result.mixHashI32(cog.x)
    result.mixHashI32(cog.y)
    result.mixHashI32(cog.vx)
    result.mixHashI32(cog.vy)
    result.mixHashI32(cog.dir)
    result.mixHashBool(cog.sprinting)
    result.mixHashBool(cog.dribbling)
    result.mixHashI32(cog.stamina)
    result.mixHashI32(cog.slideTicks)
    result.mixHashI32(cog.groundedTicks)
    result.mixHashI32(cog.passCooldown)
    result.mixHashI32(cog.shotCooldown)
    result.mixHashI32(cog.slideDirX)
    result.mixHashI32(cog.slideDirY)
    result.mixHashBool(cog.slideTouchedBall)
    result.mixHashI32(cog.team)
    result.mixHashI32(cog.shirt)
    result.mixHashI32(cog.seat)
  for team in Team:
    result.mixHashI32(sim.teamStats[team].goals)
    result.mixHashI32(sim.teamStats[team].shots)
    result.mixHashI32(sim.teamStats[team].shotsOnTarget)
    result.mixHashI32(sim.teamStats[team].saves)
    result.mixHashI32(sim.teamStats[team].possessionTicks)
    result.mixHashI32(sim.teamStats[team].passes)
    result.mixHashI32(sim.teamStats[team].tackles)
  for stats in sim.cogStats:
    result.mixHashI32(stats.goals)
    result.mixHashI32(stats.assists)
    result.mixHashI32(stats.passes)
    result.mixHashI32(stats.passesCompleted)
    result.mixHashI32(stats.interceptions)
    result.mixHashI32(stats.shots)
    result.mixHashI32(stats.shotsOnTarget)
    result.mixHashI32(stats.tackles)
    result.mixHashI32(stats.fouls)
  result.mixHashI32(sim.lastTouch.cog)
  result.mixHashI32(sim.lastTouch.team)
  result.mixHashI32(sim.lastTouch.tick)
  result.mixHashI32(sim.prevTouch.cog)
  result.mixHashI32(sim.prevTouch.team)
  result.mixHashI32(sim.prevTouch.tick)
  result.mixHashI32(sim.pendingPass.team)
  result.mixHashI32(sim.pendingPass.cog)
  result.mixHashI32(sim.pendingPass.tick)
  result.mixHashI32(sim.pendingPass.target)
  result.mixHashI32(sim.pendingShotTeam)
  result.mixHashI32(sim.pendingShotCog)
  result.mixHashI32(sim.pendingShotTick)
  result.mixHashInt(sim.players.len)
  for player in sim.players:
    result.mixHashI32(player.joinOrder)
    result.mixHashI32(player.seat)

const StateDigestTicks* = 120
  ## How often the server records a state checkpoint into the replay (5 s of
  ## match time). The hash chain says a replay diverged; a checkpoint says
  ## WHICH FIELD did, which is the difference between a bug you can fix and a
  ## bug you can only observe. At ~3 KB a checkpoint this is ~145 KB on a full
  ## match — the replay budget is 1.5 MB.

proc stateDigest*(sim: SimServer): string =
  ## Every field `gameHash` mixes, as `name=value;` text. Recorded by the
  ## server every StateDigestTicks and compared by `tools/ci/rehash_probe.nim`
  ## against its own re-simulation, so a divergence names the field instead of
  ## just the tick.
  result = newStringOfCap(4096)
  template put(name: string, value: untyped) =
    result.add(name)
    result.add('=')
    result.add($value)
    result.add(';')
  put("tick", sim.tickCount)
  put("phase", ord(sim.phase))
  put("winner", ord(sim.winner))
  put("draw", ord(sim.isDraw))
  put("ended", ord(sim.ended))
  put("reason", ord(sim.endReason))
  put("rule", ord(sim.endRule))
  put("overTimer", sim.gameOverTimer)
  put("gameStart", sim.gameStartTick)
  put("startWait", sim.startWaitTimer)
  put("lobbyWait", sim.lobbyWaitTimer)
  put("half", sim.half)
  put("rsKind", ord(sim.restartKind))
  put("rsTeam", sim.restartTeam)
  put("rsTaker", sim.restartTaker)
  put("rsTicks", sim.restartTicks)
  put("rsX", sim.restartX)
  put("rsY", sim.restartY)
  put("stale", sim.stalemateTicks)
  put("anchorX", sim.anchorX)
  put("anchorY", sim.anchorY)
  put("rngDraws", sim.rngDraws)
  put("joinOrder", sim.nextJoinOrder)
  put("players", sim.players.len)
  put("ballX", sim.ball.x)
  put("ballY", sim.ball.y)
  put("ballVX", sim.ball.vx)
  put("ballVY", sim.ball.vy)
  put("ballZ", sim.ball.z)
  put("ballVZ", sim.ball.vz)
  put("ballCtrl", sim.ball.controller)
  put("ballDead", ord(sim.ball.dead))
  put("touchCog", sim.lastTouch.cog)
  put("touchTick", sim.lastTouch.tick)
  put("prevCog", sim.prevTouch.cog)
  put("prevTick", sim.prevTouch.tick)
  put("passCog", sim.pendingPass.cog)
  put("passTick", sim.pendingPass.tick)
  put("shotCog", sim.pendingShotCog)
  put("shotTick", sim.pendingShotTick)
  put("trail", sim.trail.len)
  put("arcs", sim.arcs.len)
  put("goalFx", sim.goalFx.len)
  for team in Team:
    let p = "t" & $ord(team)
    put(p & "goals", sim.teamStats[team].goals)
    put(p & "shots", sim.teamStats[team].shots)
    put(p & "sot", sim.teamStats[team].shotsOnTarget)
    put(p & "saves", sim.teamStats[team].saves)
    put(p & "poss", sim.teamStats[team].possessionTicks)
    put(p & "passes", sim.teamStats[team].passes)
    put(p & "tackles", sim.teamStats[team].tackles)
  for i in 0 ..< CogCount:
    let
      c = sim.cogs[i]
      p = "c" & $i
    put(p & "x", c.x)
    put(p & "y", c.y)
    put(p & "vx", c.vx)
    put(p & "vy", c.vy)
    put(p & "dir", c.dir)
    put(p & "spr", ord(c.sprinting))
    put(p & "dri", ord(c.dribbling))
    put(p & "sta", c.stamina)
    put(p & "sl", c.slideTicks)
    put(p & "gr", c.groundedTicks)
    put(p & "pc", c.passCooldown)
    put(p & "sc", c.shotCooldown)
    put(p & "stb", ord(c.slideTouchedBall))

proc emitEvent*(
  sim: var SimServer,
  kind: SimEventKind,
  source = -1,
  target = -1,
  team = -1,
  amount = 0,
  x: int32 = 0,
  y: int32 = 0,
  speed: int32 = 0,
  content = ""
) {.inline.} =
  ## Appends one tier-2 analysis event. A no-op unless `collectEvents` is on,
  ## so a live server that nobody is analysing pays nothing.
  if not sim.collectEvents:
    return
  sim.events.add SimEvent(
    tick: sim.tickCount,
    kind: kind,
    source: source,
    target: target,
    team: team,
    amount: amount,
    x: x,
    y: y,
    speed: speed,
    content: content
  )

proc emitPhaseChange*(sim: var SimServer, newPhase: GamePhase) {.inline.} =
  ## Call BEFORE assigning sim.phase, with the phase being switched to.
  if not sim.collectEvents:
    return
  sim.emitEvent(PhaseChange, amount = ord(newPhase),
    content = ($newPhase).toLowerAscii)
