## Replay broadcast state channel.
##
## Derives the designed broadcast client's JSON chrome state from the live sim,
## and folds the replay's chat records back into the non-hashed presentation
## fields so the feed reads identically live and in playback.
##
## Beat-event derivation works ONE SIM STEP AT A TIME (`stepEvents`) and is
## accumulated by the caller across a playback frame, so attribution stays
## exact even at 16x — never collapsing a whole span into one ambiguous marker.
## Kept from ctf; the vocabulary is football's.
##
## The team keys are `red` and `blue` because those are the keys the inherited
## `client/chrome_common.js` already knows, and that file is copied byte for
## byte. `teams.<team>.lives` carries GOALS for the same reason: the shared
## momentum curve reads that field name, so a football scoreline drives the
## inherited graph with no edit to the inherited file.

import
  std/[json, strutils],
  sim, roster, global

type
  BroadcastTracker* = object
    ## Per-server snapshot used to diff one sim step against the previous one.
    initialized: bool
    prevTick: int
    prevPhase: GamePhase
    goals: array[Team, int32]
    shots: array[Team, int32]
    onTarget: array[Team, int32]
    saves: array[Team, int32]
    tackles: array[Team, int32]
    passes: array[Team, int32]
    fouls: int32
    lastTouchCog: int32
    lastTouchTick: int32
    lastGoalTick: int32
    lastDropTick: int32
    lastRestartTick: int32
    lastHalfTimeTick: int32
    turn: int

proc initBroadcastTracker*(): BroadcastTracker =
  result.prevPhase = Lobby
  result.lastTouchCog = -1
  result.lastGoalTick = -1
  result.lastDropTick = -1
  result.lastRestartTick = -1
  result.lastHalfTimeTick = -1
  result.turn = -1

proc totalFouls(sim: SimServer): int32 =
  for stats in sim.cogStats:
    result += stats.fouls

proc snapshot(tracker: var BroadcastTracker, sim: SimServer) =
  for team in Team:
    tracker.goals[team] = sim.teamStats[team].goals
    tracker.shots[team] = sim.teamStats[team].shots
    tracker.onTarget[team] = sim.teamStats[team].shotsOnTarget
    tracker.saves[team] = sim.teamStats[team].saves
    tracker.tackles[team] = sim.teamStats[team].tackles
    tracker.passes[team] = sim.teamStats[team].passes
  tracker.fouls = sim.totalFouls()
  tracker.lastTouchCog = sim.lastTouch.cog
  tracker.lastTouchTick = sim.lastTouch.tick
  tracker.lastGoalTick = sim.lastGoalTick
  tracker.lastDropTick = sim.lastDropTick
  tracker.lastRestartTick = sim.lastRestartTick
  tracker.lastHalfTimeTick = sim.lastHalfTimeTick
  tracker.prevTick = sim.tickCount
  tracker.prevPhase = sim.phase
  tracker.turn = sim.currentTurn()
  tracker.initialized = true

proc resync*(tracker: var BroadcastTracker, sim: SimServer) =
  ## Snapshots without emitting events, after a seek/loop/skip. The next
  ## `stepEvents` then diffs against this frame, so no phantom beats fire.
  tracker.snapshot(sim)

proc stepEvents*(
  sim: SimServer,
  tracker: var BroadcastTracker,
  events: JsonNode
) =
  ## Appends the beat events produced by the transition from the tracker's last
  ## snapshot to the current sim tick, then advances the tracker.
  ##
  ## The SCRUBBER BEATS are the subset with a CSS rule in the appended game
  ## block: `gamestart`, `goal` (red/blue), `shot` (on target only), `save`,
  ## `foul`, `halftime`, `gameover`. Nothing else is emitted as a beat.
  if not tracker.initialized:
    tracker.snapshot(sim)
    return
  let tick = sim.tickCount

  if sim.phase != tracker.prevPhase:
    events.add(%*{"t": tick, "k": "phase",
      "phase": ($sim.phase).toLowerAscii})
    if sim.phase == Playing:
      events.add(%*{"t": tick, "k": "gamestart",
        "team": teamText(Team(sim.restartTeam and 1))})
    if sim.phase == GameOver:
      events.add(%*{
        "t": tick,
        "k": "gameover",
        "winner": (if sim.isDraw: "" else: teamText(sim.winner)),
        "draw": sim.isDraw,
        "reason": reasonText(sim.endReason),
        "endRule": endRuleText(sim.endRule),
        "score": [sim.goals(Red), sim.goals(Blue)]
      })

  for team in Team:
    if sim.teamStats[team].goals > tracker.goals[team]:
      events.add(%*{
        "t": tick, "k": "goal", "team": teamText(team),
        "by": (if sim.lastGoalBy >= 0: cogId(int(sim.lastGoalBy)) else: ""),
        "assist": (
          if sim.lastGoalAssist >= 0: %cogId(int(sim.lastGoalAssist))
          else: newJNull()),
        "speed": float(sim.lastGoalSpeed) * 24.0 / 1_000_000.0,
        "score": [sim.goals(Red), sim.goals(Blue)]
      })
    if sim.teamStats[team].shots > tracker.shots[team]:
      events.add(%*{"t": tick, "k": "shot", "team": teamText(team),
        "onTarget": sim.teamStats[team].shotsOnTarget > tracker.onTarget[team]})
    if sim.teamStats[team].saves > tracker.saves[team]:
      events.add(%*{"t": tick, "k": "save", "team": teamText(team)})
    if sim.teamStats[team].tackles > tracker.tackles[team]:
      events.add(%*{"t": tick, "k": "tackle", "team": teamText(team)})
    if sim.teamStats[team].passes > tracker.passes[team]:
      events.add(%*{"t": tick, "k": "pass", "team": teamText(team)})

  if sim.totalFouls() > tracker.fouls:
    events.add(%*{"t": tick, "k": "foul",
      "team": (if sim.restartTeam >= 0:
        teamText(other(Team(sim.restartTeam and 1))) else: "")})

  # A touch is a new last-toucher, throttled so a scrum cannot flood the feed.
  if sim.lastTouch.cog >= 0 and
      (sim.lastTouch.cog != tracker.lastTouchCog or
       sim.lastTouch.tick - tracker.lastTouchTick >= TouchThrottleTicks):
    if sim.lastTouch.tick == int32(tick):
      events.add(%*{"t": tick, "k": "touch",
        "by": cogId(int(sim.lastTouch.cog)),
        "team": teamText(teamOfCog(int(sim.lastTouch.cog)))})

  if sim.lastDropTick >= 0 and sim.lastDropTick != tracker.lastDropTick:
    events.add(%*{"t": tick, "k": "drop"})

  if sim.lastHalfTimeTick >= 0 and
      sim.lastHalfTimeTick != tracker.lastHalfTimeTick:
    events.add(%*{"t": tick, "k": "halftime"})

  if sim.lastRestartTick >= 0 and
      sim.lastRestartTick != tracker.lastRestartTick:
    events.add(%*{"t": tick, "k": "restart",
      "kind": restartText(sim.restartKind),
      "team": (if sim.restartTeam >= 0:
        teamText(Team(sim.restartTeam and 1)) else: "")})

  if sim.phase == Playing and sim.currentTurn() != tracker.turn and
      tracker.turn >= 0:
    events.add(%*{"t": tick, "k": "turn_end", "turn": tracker.turn})

  tracker.snapshot(sim)

# --------------------------------------------------------------------------
# Replay chat records -> the non-hashed presentation fields
# --------------------------------------------------------------------------

proc applyRecord*(sim: var SimServer, text: string) =
  ## Folds ONE replay chat record back into the sim's presentation state. This
  ## is the single place the feed is written, so a live broadcast and a replay
  ## tell exactly the same story. Records can never affect the sim: everything
  ## touched here is outside `gameHash`.
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return
  if node.kind != JObject:
    return
  let kind = node{"k"}.getStr()
  let seat = node{"seat"}.getInt(-1)
  case kind
  of "register":
    if seat in 0 ..< SeatCount:
      for i in 0 ..< sim.players.len:
        if int(sim.players[i].seat) == seat:
          sim.players[i].policyLabel = node{"policy"}.getStr()
          sim.players[i].policyKind =
            if node{"kind"}.getStr() == "llm": pkLlm else: pkScripted
          sim.players[i].baseline = node{"baseline"}.getStr()
          sim.players[i].registered = true
      sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "register",
        team: int32(ord(teamOfSeat(seat))),
        text: cogId(cogOfSeat(seat)) & ": " & node{"kind"}.getStr() & " policy")
  of "directive":
    if seat notin 0 ..< SeatCount:
      return
    let
      team = teamOfSeat(seat)
      note = node{"note"}.getStr()
    if note.len > 0:
      sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "note",
        team: int32(ord(team)),
        text: cogId(cogOfSeat(seat)) & " plan: " & note)
    let cogs = node{"cogs"}
    if not cogs.isNil and cogs.kind == JArray:
      for entry in cogs:
        let say = entry{"say"}.getStr()
        if say.len > 0:
          sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "say",
            team: int32(ord(team)),
            text: entry{"id"}.getStr() & ": " & say)
  of "fallback":
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "fallback",
      team: (if seat >= 0 and seat < SeatCount:
        int32(ord(teamOfSeat(seat))) else: -1),
      text: "seat fell back (" & node{"cause"}.getStr() & ")")
  of "budget_guard":
    sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "fallback",
      team: -1, text: "decision budget guard: scripted for the rest")
  else:
    discard
  while sim.feed.len > 64:
    sim.feed.delete(0)

# --------------------------------------------------------------------------
# The chrome frame
# --------------------------------------------------------------------------

proc teamPoliciesJson(sim: SimServer, team: Team): JsonNode =
  ## The distinct policy identities seated on one side. Real names, SPECTATOR
  ## side only — the board labels and the seat views never carry them.
  result = newJArray()
  var seen: seq[string]
  for player in sim.players:
    if player.team != team or player.address.len == 0:
      continue
    let name = policyName(player.address)
    if name notin seen:
      seen.add(name)
      result.add(%name)
  if result.len == 0:
    for seat in 0 ..< SeatCount:
      if teamOfSeat(seat) != team:
        continue
      if seat < sim.config.slots.len and sim.config.slots[seat].name.len > 0:
        let name = sim.config.slots[seat].name
        if name notin seen:
          seen.add(name)
          result.add(%name)

proc teamStateJson(sim: SimServer, team: Team): JsonNode =
  ## One team's scorebug state. `lives` mirrors `goals` so the inherited
  ## momentum curve (which reads `lives`) draws goal difference unchanged.
  let
    mine = int(sim.teamStats[team].possessionTicks)
    theirs = int(sim.teamStats[other(team)].possessionTicks)
    total = max(1, mine + theirs)
  %*{
    "goals": sim.goals(team),
    "lives": sim.goals(team),
    "poss": mine * 100 div total,
    "shots": int(sim.teamStats[team].shots),
    "sot": int(sim.teamStats[team].shotsOnTarget),
    "saves": int(sim.teamStats[team].saves),
    "passes": int(sim.teamStats[team].passes),
    "tackles": int(sim.teamStats[team].tackles),
    "policies": sim.teamPoliciesJson(team)
  }

proc rosterJson(sim: SimServer): JsonNode =
  ## One entry per CONNECTION (eight), keyed by stable join slot. The chrome
  ## reads `name`/`pol` for the scorebug headline; the board never does.
  result = newJArray()
  for player in sim.players:
    let index = cogOfSeat(int(player.seat))
    result.add(%*{
      "s": int(player.joinOrder),
      "team": teamText(player.team),
      "name": player.address,
      "pol": policyName(player.address),
      "alias": cogId(index),
      "shirt": int(player.shirt),
      "kind": policyKindText(player.policyKind),
      "alive": true,
      "lives": 0,
      "goals": int(sim.cogStats[index].goals),
      "shots": int(sim.cogStats[index].shots)
    })

proc feedJson(sim: SimServer): JsonNode =
  result = newJArray()
  for line in sim.feed:
    result.add(%*{
      "t": int(line.tick), "k": line.kind,
      "team": (if line.team >= 0: teamText(Team(line.team and 1)) else: ""),
      "text": line.text
    })

proc directivesJson(sim: SimServer): JsonNode =
  ## The active order per seat, for the feed and the match story. Aliases only.
  result = newJArray()
  for seat in 0 ..< SeatCount:
    if not sim.hasDirective[seat]:
      continue
    let d = sim.activeDirective[seat]
    result.add(%*{
      "k": "directive",
      "turn": int(d.turn),
      "seat": seat,
      "id": cogId(cogOfSeat(seat)),
      "team": teamText(teamOfSeat(seat)),
      "source": sourceText(d.source),
      "note": d.note,
      "cogs": [{
        "id": cogId(cogOfSeat(seat)),
        "intent": intentText(d.cog.intent),
        "say": d.cog.say
      }]
    })

proc buildStateJson*(
  sim: SimServer,
  events: JsonNode,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int,
  povSlot: int,
  leadSeries: seq[seq[int]] = @[],
  startTick: int = 0,
  endHoldSeconds: int = 0,
  includeFpMap: bool = false,
  skipLulls: bool = false,
  fastForwarding: bool = false,
  lullSpans: seq[array[2, int]] = @[],
  beatEvents: JsonNode = nil
): string =
  ## Assembles the broadcast chrome frame. Board-derived STATE (score,
  ## possession, roster, verdict) is always present, so even a frame reached by
  ## a seek hydrates the scorebug and end-card with no events.
  var teams = newJObject()
  for team in Team:
    teams[teamText(team)] = sim.teamStateJson(team)

  var state = %*{
    "t": sim.tickCount,
    "mt": sim.effectiveMaxTicks(),
    "ph": ($sim.phase).toLowerAscii,
    "lob": sim.lobbyStartSecondsRemaining(),
    "pl": playing,
    "sp": speed,
    "mx": maxTick,
    "st": startTick,
    "lp": looping,
    "sk": skipLulls,
    "ff": fastForwarding,
    "en": transportEnabled,
    "mm": mismatchTick,
    "bs": boardRenderScaleFor(MapWidth, MapHeight),
    "pov": -1,
    "half": int(sim.half),
    "turn": sim.currentTurn(),
    "turns": sim.turnCount(),
    "turnTicks": sim.turnTicks(),
    "game": 1,
    "games": 1,
    "restart": {
      "kind": restartText(sim.restartKind),
      "team": (if sim.restartTeam >= 0:
        teamText(Team(sim.restartTeam and 1)) else: ""),
      "taker": (if sim.restartTaker >= 0:
        cogId(int(sim.restartTaker)) else: ""),
      "ticks": int(sim.restartTicks)
    },
    "ball": {
      "x": worldToBoard(sim.ball.x),
      "y": worldToBoard(sim.ball.y),
      "z": int(sim.ball.z),
      "ctrl": int(sim.ball.controller)
    },
    "teams": teams,
    "roster": sim.rosterJson(),
    "feed": sim.feedJson(),
    "directives": sim.directivesJson(),
    "events": (if events.isNil: newJArray() else: events)
  }
  discard povSlot

  # Full-timeline goal series (sent ONCE per HUD viewer) so the momentum graph
  # draws its whole-timeline shape immediately instead of accumulating to the
  # playhead.
  if leadSeries.len > 0:
    var teamNames = newJArray()
    for team in Team:
      teamNames.add(%teamText(team))
    var points = newJArray()
    for point in leadSeries:
      var row = newJArray()
      for value in point:
        row.add(%value)
      points.add(row)
    state["lead"] = %*{"teams": teamNames, "pts": points}

  if not beatEvents.isNil and beatEvents.len > 0:
    state["beats"] = beatEvents

  if lullSpans.len > 0:
    var spans = newJArray()
    for span in lullSpans:
      spans.add(%*[span[0], span[1]])
    state["lulls"] = spans

  # The end-card is STATE, not an event: present on every game-over frame so a
  # viewer who seeks straight to the end still sees the verdict.
  if sim.phase == GameOver:
    var overTeams = newJObject()
    for team in Team:
      var best = 0
      for seat in 0 ..< SeatCount:
        if teamOfSeat(seat) == team:
          best = max(best, sim.scorePermille(seat))
      overTeams[teamText(team)] = %*{
        "goals": sim.goals(team),
        "lives": sim.goals(team),
        "score": float(best) / 1000.0
      }
    state["over"] = %*{
      "winner": (if sim.isDraw: "" else: teamText(sim.winner)),
      "draw": sim.isDraw,
      "reason": reasonText(sim.endReason),
      "endRule": endRuleText(sim.endRule),
      "timeLimit": sim.endRule == erFullTime,
      "teams": overTeams
    }
    if endHoldSeconds > 0:
      state["hold"] = %endHoldSeconds
  discard includeFpMap
  $state
