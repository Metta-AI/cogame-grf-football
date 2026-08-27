## Shared helpers for the grf-football test suite.
##
## Every test runs from the repo ROOT (assets resolve via `data/`), twice: once
## debug — where Nim's range and overflow checks are the cheapest catch for a
## fixed-point overflow — and once `-d:release`.

import std/[os, random, strutils]
import grf_football/[baselines, broadcast, builtin_ai, control, decide,
  directives, events, global, llm, replay_runtime, replays, roster, sim]

export sim, control, builtin_ai, baselines, directives, decide, roster,
  broadcast, events, global, llm, replays, replay_runtime

proc testConfig*(seed = 679961, maxTicks = DefaultMaxTicks): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.maxTicks = maxTicks
  result.halfTicks = maxTicks div 2
  result.minPlayers = SeatCount
  result.startWaitTicks = 1
  result.gameOverTicks = 2
  result.turnSpacingMs = 0
  result.slots = @[]
  for seat in 0 ..< SeatCount:
    result.slots.add PlayerSlotConfig(
      name: "policy-" & $seat, token: "t" & $seat,
      team: teamOfSeat(seat), hasTeam: true)

proc seatedSim*(config: GameConfig): SimServer =
  ## A sim with all eight seats already joined THROUGH `addPlayer`, logging off.
  ## Adding roster entries by hand would leave `nextJoinOrder` behind, and that
  ## field IS hashed — a replay of such a recording diverges at tick 1.
  result = initSimServer(config)
  result.gameEventLoggingEnabled = false
  for seat in 0 ..< SeatCount:
    discard result.addPlayer("policy-" & $seat, seat, "t" & $seat)

proc playing*(config: GameConfig): SimServer =
  ## A sim already in the Playing phase, past the kickoff restart.
  result = seatedSim(config)
  result.startGame()
  result.restartTicks = 0
  result.restartKind = rkNone
  result.ball.dead = false

proc zeroActions*(): seq[uint8] =
  newSeq[uint8](CogCount)

proc stepWith*(sim: var SimServer, actions: array[CogCount, uint8]) =
  var buffer = newSeq[uint8](CogCount)
  for i in 0 ..< CogCount:
    buffer[i] = actions[i]
  sim.step(buffer, buffer)

proc stepIdle*(sim: var SimServer, ticks = 1) =
  let idle = zeroActions()
  for _ in 0 ..< ticks:
    sim.step(idle, idle)

type ScriptedMatch* = object
  goals*: array[Team, int]
  ticks*: int
  reason*: EndReason
  rule*: EndRule
  actions*: seq[array[CogCount, uint8]]

proc runScriptedMatch*(
  config: GameConfig,
  red = "zonal",
  blue = "zonal",
  collectActions = false
): ScriptedMatch =
  ## A whole episode driven by the scripted baselines through the REAL control
  ## layer — the same path the server takes, minus the sockets.
  var sim = seatedSim(config)
  var directives: array[SeatCount, Directive]
  for seat in 0 ..< SeatCount:
    directives[seat] = emptyDirective(seat)
  var prev = newSeq[uint8](CogCount)
  var guard = 0
  while sim.phase != GameOver and guard < config.maxTicks * 3 + 5000:
    inc guard
    if sim.phase == Playing:
      let elapsed = sim.tickCount - sim.gameStartTick
      var opening = false
      for seat in 0 ..< SeatCount:
        if not sim.hasDirective[seat]:
          opening = true
      if opening or elapsed mod sim.turnTicks() == 0:
        let turn = elapsed div sim.turnTicks()
        for seat in 0 ..< SeatCount:
          let name = if teamOfSeat(seat) == Red: red else: blue
          directives[seat] = sim.baselineDirective(seat, name, turn)
          sim.activeDirective[seat] = directives[seat]
          sim.hasDirective[seat] = true
    let actions = sim.compileActions(sim.activeDirective)
    if collectActions:
      result.actions.add(actions)
    var buffer = newSeq[uint8](CogCount)
    for i in 0 ..< CogCount:
      buffer[i] = actions[i]
    sim.step(buffer, prev)
    prev = buffer
  for team in Team:
    result.goals[team] = sim.goals(team)
  result.ticks = sim.tickCount
  result.reason = sim.endReason
  result.rule = sim.endRule

proc strippedSource*(path: string): string =
  ## Reads a source file with `##`/`#` comments and string literals stripped,
  ## so a guard can grep for IDENTIFIERS without tripping over prose.
  let raw = readFile(path)
  var
    stripped = newStringOfCap(raw.len)
    inString = false
    inChar = false
    escaped = false
    comment = false
    prev = ' '
  for ch in raw:
    if comment:
      if ch == '\n':
        comment = false
        stripped.add(ch)
      continue
    if inString:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '"': inString = false
      continue
    if inChar:
      if escaped: escaped = false
      elif ch == '\\': escaped = true
      elif ch == '\'': inChar = false
      continue
    case ch
    of '#':
      comment = true
    of '"':
      inString = true
    of '\'':
      # A quote after an alphanumeric is a NUMERIC SUFFIX (`1'i64`), not a char
      # literal. Missing that swallows half the file and makes this guard
      # silently useless.
      if prev in {'0' .. '9', 'A' .. 'Z', 'a' .. 'z', '_'}:
        stripped.add(ch)
      else:
        inChar = true
    else:
      stripped.add(ch)
    prev = ch
  stripped

proc identifiers*(text: string): seq[string] =
  ## Every maximal [A-Za-z0-9_] run in `text`.
  var current = ""
  for ch in text:
    if ch in {'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_'}:
      current.add(ch)
    elif current.len > 0:
      result.add(current)
      current = ""
  if current.len > 0:
    result.add(current)

proc tempPath*(name: string): string =
  getTempDir() / ("grf-football-test-" & $getCurrentProcessId() & "-" & name)

proc report*(name: string) =
  echo "  ok  ", name

proc pseudoWorld*(sim: var SimServer, rng: var Rand) =
  ## Scatters the 23 bodies over the pitch deterministically — the state
  ## generator the bounded-orders and control tests sweep over.
  sim.ball.x = int32(PitchXMin + rng.rand(int(PitchXMax - PitchXMin)))
  sim.ball.y = int32(PitchYMin + rng.rand(int(PitchYMax - PitchYMin)))
  sim.ball.vx = int32(rng.rand(2 * int(BallMaxSpeed)) - int(BallMaxSpeed))
  sim.ball.vy = int32(rng.rand(2 * int(BallMaxSpeed)) - int(BallMaxSpeed))
  sim.ball.z = 0
  sim.ball.vz = 0
  sim.ball.controller = int32(rng.rand(CogCount * 2) - CogCount)
  if sim.ball.controller >= CogCount or sim.ball.controller < 0:
    sim.ball.controller = -1
  sim.ball.dead = false
  for i in 0 ..< CogCount:
    sim.cogs[i].x = int32(PitchXMin + rng.rand(int(PitchXMax - PitchXMin)))
    sim.cogs[i].y = int32(PitchYMin + rng.rand(int(PitchYMax - PitchYMin)))
    sim.cogs[i].vx = int32(rng.rand(2 * int(SprintSpeed)) - int(SprintSpeed))
    sim.cogs[i].vy = int32(rng.rand(2 * int(SprintSpeed)) - int(SprintSpeed))
    sim.cogs[i].dir = int32(rng.rand(8))
    sim.cogs[i].stamina = int32(rng.rand(int(StaminaMax)))
    sim.cogs[i].sprinting = rng.rand(1) == 1
    sim.cogs[i].dribbling = rng.rand(1) == 1
    sim.cogs[i].passCooldown = int32(rng.rand(int(PassCooldownTicks)))
    sim.cogs[i].shotCooldown = int32(rng.rand(int(ShotCooldownTicks)))

proc runeCount*(text: string): int =
  ## Codepoints, not bytes — the unit every recorded string is capped in.
  var count = 0
  var i = 0
  while i < text.len:
    let b = text[i].uint8
    let width =
      if b < 0x80: 1
      elif b < 0xE0: 2
      elif b < 0xF0: 3
      else: 4
    i += width
    inc count
  count

proc isValidUtf8*(text: string): bool =
  ## A byte-truncated multi-byte character is exactly the bug the rune
  ## discipline exists to prevent, so the tests check for it directly.
  var i = 0
  while i < text.len:
    let b = text[i].uint8
    var extra = 0
    if b < 0x80: extra = 0
    elif b >= 0xC2 and b <= 0xDF: extra = 1
    elif b >= 0xE0 and b <= 0xEF: extra = 2
    elif b >= 0xF0 and b <= 0xF4: extra = 3
    else: return false
    if i + extra >= text.len and extra > 0:
      return false
    for k in 1 .. extra:
      let c = text[i + k].uint8
      if c < 0x80 or c > 0xBF:
        return false
    i += extra + 1
  true

proc containsText*(haystack, needle: string): bool =
  needle.len > 0 and haystack.contains(needle)
