## GameConfig lifecycle: defaults, the JSON reader, validation, update, and the
## config echo (`configJson`) that every replay carries in its header. Kept in
## ctf's shape (`sim_config.nim`), with grf-football's fields.
##
## Every field read here must appear in `game.config_schema` in
## coworld_manifest_template.json — `tests/test_manifest.nim` asserts the two
## agree, because the certifier rejects an unknown config key.

import
  std/[json, strutils],
  sim_types

proc defaultGameConfig*(): GameConfig =
  ## The default grf-football match: eight seats, 24 turns, 4:00 of football.
  GameConfig(
    seed: DefaultSeed,
    speed: 1,
    numAgents: SeatCount,
    minPlayers: DefaultMinPlayers,
    startWaitTicks: DefaultStartWaitTicks,
    lobbyJoinTimeoutTicks: DefaultLobbyJoinTimeoutTicks,
    gameOverTicks: DefaultGameOverTicks,
    maxTicks: DefaultMaxTicks,
    halfTicks: DefaultHalfTicks,
    maxGames: DefaultMaxGames,
    turnTicks: DefaultTurnTicks,
    turnBudgetMs: DefaultTurnBudgetMs,
    attempt1Ms: DefaultAttempt1Ms,
    retryMs: DefaultRetryMs,
    turnSpacingMs: DefaultTurnSpacingMs,
    wallClockBudgetSeconds: DefaultWallClockBudgetSeconds,
    mercyGoalDiff: DefaultMercyGoalDiff,
    restartTicks: DefaultRestartTicks,
    stalemateTicks: DefaultStalemateTicks,
    fastMode: true,
    showPlayerLabels: false,
    closedRoster: false,
    model: DefaultModel,
    maxOutputTokens: DefaultMaxOutputTokens,
    baseSpeed: int(BaseSpeed),
    sprintSpeed: int(SprintSpeed),
    shotSpeed: int(ShotSpeed),
    shortPassSpeed: int(ShortPassSpeed),
    longPassSpeed: int(LongPassSpeed),
    slots: @[]
  )

proc readInt(node: JsonNode, key: string, target: var int) =
  if node.hasKey(key) and node[key].kind in {JInt, JFloat}:
    target = node[key].getInt()

proc readBool(node: JsonNode, key: string, target: var bool) =
  if node.hasKey(key) and node[key].kind == JBool:
    target = node[key].getBool()

proc readStr(node: JsonNode, key: string, target: var string) =
  if node.hasKey(key) and node[key].kind == JString:
    target = node[key].getStr()

proc teamOfText*(text: string): Team =
  ## Parses a slot's team name. Unknown names seat Red; the loader below also
  ## honours plain indices so a variant may say `{"team": 1}`.
  case text.strip().toLowerAscii()
  of "blue", "1": Blue
  else: Red

proc readSlots(node: JsonNode, config: var GameConfig) =
  ## `slots` fixes each seat's side; `players` names them; `tokens` authorises
  ## them. All three are positional and the platform always sends them
  ## together, so one pass fills the slot table.
  var count = 0
  for key in ["slots", "players", "tokens"]:
    if node.hasKey(key) and node[key].kind == JArray:
      count = max(count, node[key].len)
  if count == 0:
    return
  var slots = newSeq[PlayerSlotConfig](count)
  for i in 0 ..< count:
    slots[i].team = teamOfSeat(i)
    slots[i].hasTeam = true
  if node.hasKey("slots") and node["slots"].kind == JArray:
    for i in 0 ..< node["slots"].len:
      let entry = node["slots"][i]
      if i >= count or entry.kind != JObject:
        continue
      if entry.hasKey("team"):
        case entry["team"].kind
        of JString:
          slots[i].team = teamOfText(entry["team"].getStr())
        of JInt:
          slots[i].team = if entry["team"].getInt() == 1: Blue else: Red
        else:
          discard
        slots[i].hasTeam = true
  if node.hasKey("players") and node["players"].kind == JArray:
    for i in 0 ..< node["players"].len:
      let entry = node["players"][i]
      if i >= count:
        continue
      case entry.kind
      of JString:
        slots[i].name = entry.getStr()
      of JObject:
        if entry.hasKey("name") and entry["name"].kind == JString:
          slots[i].name = entry["name"].getStr()
      else:
        discard
  if node.hasKey("tokens") and node["tokens"].kind == JArray:
    for i in 0 ..< node["tokens"].len:
      let entry = node["tokens"][i]
      if i < count and entry.kind == JString:
        slots[i].token = entry.getStr()
  config.slots = slots

proc validate*(config: GameConfig) =
  ## Rejects a config that cannot produce a legal match, loudly and before any
  ## socket opens (ctf's contract: the entrypoint dies with a clean message).
  if config.numAgents != SeatCount:
    raise newException(GrfFootballError,
      "num_agents must be " & $SeatCount & ", got " & $config.numAgents)
  if config.maxTicks <= 0:
    raise newException(GrfFootballError, "maxTicks must be positive")
  if config.halfTicks <= 0:
    raise newException(GrfFootballError, "halfTicks must be positive")
  if config.turnTicks <= 0:
    raise newException(GrfFootballError, "turnTicks must be positive")
  if config.turnBudgetMs < config.attempt1Ms + config.retryMs:
    raise newException(GrfFootballError,
      "turnBudgetMs must cover attempt1Ms + retryMs")
  # curl's CURLOPT_TIMEOUT granularity is WHOLE SECONDS, so a sub-second
  # deadline is not a deadline at all -- it floors to curly's own one-second
  # minimum and the turn budget stops bounding anything. The starter's scar.
  if config.attempt1Ms > 0 and config.attempt1Ms < 1000:
    raise newException(GrfFootballError,
      "attempt1Ms must be 0 or at least 1000 (curl timeouts are whole seconds)")
  if config.retryMs > 0 and config.retryMs < 1000:
    raise newException(GrfFootballError,
      "retryMs must be 0 or at least 1000 (curl timeouts are whole seconds)")
  if config.turnSpacingMs < 0:
    raise newException(GrfFootballError, "turnSpacingMs must not be negative")
  if config.wallClockBudgetSeconds <= 0:
    raise newException(GrfFootballError,
      "wallClockBudgetSeconds must be positive")
  if config.minPlayers < 1 or config.minPlayers > SeatCount:
    raise newException(GrfFootballError,
      "minPlayers must be between 1 and " & $SeatCount)
  if config.restartTicks <= 0:
    raise newException(GrfFootballError, "restartTicks must be positive")
  if config.stalemateTicks <= 0:
    raise newException(GrfFootballError, "stalemateTicks must be positive")

proc update*(config: var GameConfig, configJson: string) =
  ## Folds one runtime config document into the defaults. Unknown keys are
  ## ignored (the platform adds fields); a malformed document raises.
  if configJson.strip().len == 0:
    config.validate()
    return
  var node: JsonNode
  try:
    node = parseJson(configJson)
  except CatchableError as error:
    raise newException(GrfFootballError,
      "config is not valid JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(GrfFootballError, "config must be a JSON object")
  node.readInt("seed", config.seed)
  node.readInt("speed", config.speed)
  node.readInt("num_agents", config.numAgents)
  node.readInt("minPlayers", config.minPlayers)
  node.readInt("startWaitTicks", config.startWaitTicks)
  node.readInt("lobbyJoinTimeoutTicks", config.lobbyJoinTimeoutTicks)
  node.readInt("gameOverTicks", config.gameOverTicks)
  node.readInt("maxTicks", config.maxTicks)
  node.readInt("halfTicks", config.halfTicks)
  node.readInt("maxGames", config.maxGames)
  node.readInt("turnTicks", config.turnTicks)
  node.readInt("turnBudgetMs", config.turnBudgetMs)
  node.readInt("attempt1Ms", config.attempt1Ms)
  node.readInt("retryMs", config.retryMs)
  node.readInt("turnSpacingMs", config.turnSpacingMs)
  node.readInt("wallClockBudgetSeconds", config.wallClockBudgetSeconds)
  node.readInt("mercyGoalDiff", config.mercyGoalDiff)
  node.readInt("restartTicks", config.restartTicks)
  node.readInt("stalemateTicks", config.stalemateTicks)
  node.readBool("fastMode", config.fastMode)
  node.readBool("showPlayerLabels", config.showPlayerLabels)
  node.readBool("closedRoster", config.closedRoster)
  node.readStr("model", config.model)
  node.readInt("maxOutputTokens", config.maxOutputTokens)
  node.readInt("baseSpeed", config.baseSpeed)
  node.readInt("sprintSpeed", config.sprintSpeed)
  node.readInt("shotSpeed", config.shotSpeed)
  node.readInt("shortPassSpeed", config.shortPassSpeed)
  node.readInt("longPassSpeed", config.longPassSpeed)
  node.readSlots(config)
  if config.speed <= 0:
    config.speed = 1
  if config.halfTicks > config.maxTicks:
    config.halfTicks = config.maxTicks
  config.validate()

proc configuredPlayerName*(config: GameConfig, slot: int, token: string):
    string =
  ## The configured display name for a joining seat, matched by slot then by
  ## token. "" when the roster does not name it.
  if slot >= 0 and slot < config.slots.len and config.slots[slot].name.len > 0:
    return config.slots[slot].name
  if token.len > 0:
    for entry in config.slots:
      if entry.token.len > 0 and entry.token == token:
        return entry.name
  ""

proc playerJoinAllowed*(
  config: GameConfig,
  address: string,
  slot: int,
  token: string
): bool =
  ## The 403 gate: a slot outside the roster, or a token that does not match
  ## the slot it claims, is refused before the websocket upgrade.
  discard address
  if slot >= MaxPlayers:
    return false
  if slot >= 0 and slot < config.slots.len:
    let want = config.slots[slot].token
    if want.len > 0 and token != want:
      return false
    return true
  if slot >= config.slots.len and config.closedRoster:
    return false
  if token.len > 0:
    for entry in config.slots:
      if entry.token.len > 0 and entry.token == token:
        return true
    if config.closedRoster:
      return false
  true

proc configJson*(config: GameConfig): string =
  ## The RESOLVED config echoed into the replay header. Playback re-derives the
  ## identical world from these bytes, so every field the sim reads is here —
  ## and nothing else: tokens are the one exception a replay legitimately
  ## carries (ctf writes them in the join records too).
  var slots = newJArray()
  var players = newJArray()
  var tokens = newJArray()
  for entry in config.slots:
    slots.add(%*{"team": teamText(entry.team)})
    players.add(%*{"name": entry.name})
    tokens.add(%entry.token)
  $(%*{
    "seed": config.seed,
    "speed": config.speed,
    "num_agents": config.numAgents,
    "minPlayers": config.minPlayers,
    "startWaitTicks": config.startWaitTicks,
    "lobbyJoinTimeoutTicks": config.lobbyJoinTimeoutTicks,
    "gameOverTicks": config.gameOverTicks,
    "maxTicks": config.maxTicks,
    "halfTicks": config.halfTicks,
    "maxGames": config.maxGames,
    "turnTicks": config.turnTicks,
    "turnBudgetMs": config.turnBudgetMs,
    "attempt1Ms": config.attempt1Ms,
    "retryMs": config.retryMs,
    "turnSpacingMs": config.turnSpacingMs,
    "wallClockBudgetSeconds": config.wallClockBudgetSeconds,
    "mercyGoalDiff": config.mercyGoalDiff,
    "restartTicks": config.restartTicks,
    "stalemateTicks": config.stalemateTicks,
    "fastMode": config.fastMode,
    "showPlayerLabels": config.showPlayerLabels,
    "closedRoster": config.closedRoster,
    "model": config.model,
    "maxOutputTokens": config.maxOutputTokens,
    "baseSpeed": config.baseSpeed,
    "sprintSpeed": config.sprintSpeed,
    "shotSpeed": config.shotSpeed,
    "shortPassSpeed": config.shortPassSpeed,
    "longPassSpeed": config.longPassSpeed,
    "worldW": int(WorldW),
    "worldH": int(WorldH),
    "pitchXMin": int(PitchXMin),
    "pitchXMax": int(PitchXMax),
    "pitchYMin": int(PitchYMin),
    "pitchYMax": int(PitchYMax),
    "goalYMin": int(GoalYMin),
    "goalYMax": int(GoalYMax),
    "cogRadius": int(CogRadius),
    "ballRadius": int(BallRadius),
    "slots": slots,
    "players": players,
    "tokens": tokens
  })
