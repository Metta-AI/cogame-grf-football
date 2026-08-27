## The sim's shared vocabulary: the core constants (including GameVersion and
## its changelog), the gameplay/wire types, and the pure helpers both sides of
## every seam need. Split out of sim.nim exactly as coworld-ctf splits its own
## (docs/plans/2026-08-01-sim-split.md in the starter) so the leaf modules
## (rig_art, pitch, sim_config, sim_state, roster) share them without importing
## gameplay.
##
## `SimServer` and friends are flatty-serialized POSITIONALLY into replay
## keyframes, so declaration/field order here is wire format — reorder nothing
## without a GameVersion bump. Append, never insert.
##
## EVERY hashed field is an explicit fixed width (`int32` / `bool` / enum).
## Nim's `int` is 64-bit natively and 32-bit under `--cpu:wasm32`, and the same
## sim module compiles both ways (native server records, emscripten viewer
## re-simulates), so a bare `int` in hashed state is a native/wasm divergence
## waiting to happen. See docs/RULES.md §Determinism.

import
  std/random,
  pixie

const
  GameName* = "grf-football"
  GameVersion* = "5"  ## GV5 (possession is the controller's): `possessionTicks`
    ## is credited to the team of the CURRENT CONTROLLER only, per the design
    ## note's resolution step 9. GV4 and earlier also credited the last toucher
    ## while the ball was loose, so the broadcast possession bar read 100 % for
    ## a team that had lost the ball. `possessionTicks` is hashed, so this
    ## obsoletes GV4's chain.
    ##
    ## GV4 (a pass can be received): ControlSpeed was 12 m/s,
    ## below the 14 m/s short pass, so a pass ricocheted off its receiver every
    ## time and a whole certification episode finished 0-0 with a single shot.
    ## It is now 18 m/s: a pass can be taken on arrival, a shot cannot.
    ## Obsoletes GV3's chain.
    ##
    ## GV3 (the stop is a record): a wall-clock stop and a
    ## host error are WALL-CLOCK FACTS — nothing in sim state implies them — so
    ## banking them outside `sim.step` and then recording the tick's hash made
    ## every `deadline` replay diverge from its own re-simulation at the stop
    ## tick, which is exactly the failure `playbooks/make-coworld.md` records
    ## against particle-worlds. The stop now travels as one load-bearing
    ## `stop` record applied by the SAME `finishGame` on both record and
    ## playback. Obsoletes GV2's chain.
    ##
    ## GV2 (strict chain): the RNG DRAW COUNT and every other
    ## field the step writes are now in `gameHash`. The seeded sim RNG is read
    ## by the step (kickoff jitter, shot aim error) but its state is private to
    ## `std/random`, so it could not be hashed directly and a drifted stream
    ## surfaced only later, as a wrong shot — a recorded episode diverged from
    ## its own re-simulation ~500 ticks after the drift with nothing to say
    ## where. A hashed draw COUNTER pins it to the tick it happens on.
    ## Obsoletes GV1's chain: a GV1 replay will not verify against this build.
    ##
    ## GV1 (first rules): eleven-a-side association football
    ## on an 84x54 m pitch, 22 cogs and 8 seats. Integer micrometre physics at
    ## 24 Hz with four substeps a tick, a 19-action gfootball byte as the
    ## recorded action log, a 240-tick decision turn, two halves of 2880 ticks,
    ## throw-ins/corners/goal kicks/free kicks, the 480-tick stalemate neutral
    ## drop, mercy at a five-goal difference and a 690 s wall-clock stop.
    ##
    ## Prepend-only changelog, ctf's discipline: say what the number means and
    ## what it obsoletes, keeping the `GVnn (short rule name): HEADLINE` shape.
    ## `tools/ci/check_gameversion.sh` diffs this headline, not the digits.

  TargetFps* = 24
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]
    ## Replay/live playback speed steps. Kept from ctf verbatim: every
    ## speed-coupled layer (the transport keymap, the lull scan, the JS
    ## clients' wire constants) derives from this ONE table.

  # ---- world geometry, micrometres -----------------------------------------
  MapScale* = 75_000          ## micrometres per rendered map pixel (0.075 m).
  MapWidth* = 1200
  MapHeight* = 800
  WorldW* = 90_000_000'i32    ## 90 m including the 3 m surround.
  WorldH* = 60_000_000'i32    ## 60 m including the 3 m surround.

  PitchXMin* = 3_000_000'i32  ## the red goal line.
  PitchXMax* = 87_000_000'i32 ## the blue goal line.
  PitchYMin* = 3_000_000'i32
  PitchYMax* = 57_000_000'i32
  CentreX* = 45_000_000'i32
  CentreY* = 30_000_000'i32
  CentreCircleR* = 9_000_000'i32
  GoalYMin* = 26_000_000'i32
  GoalYMax* = 34_000_000'i32
  GoalDepth* = 2_400_000'i32  ## netting behind each goal line.
  PostRadius* = 100_000'i32
  PenaltyDepth* = 16_000_000'i32   ## |x - own goal line| bound of a penalty area.
  PenaltyHalfH* = 20_000_000'i32   ## |y - CentreY| bound of a penalty area.
  SixYardDepth* = 5_500_000'i32
  SixYardHalfH* = 10_000_000'i32

  BoardXMin* = 300_000'i32
  BoardXMax* = 89_700_000'i32
  BoardYMin* = 300_000'i32
  BoardYMax* = 59_700_000'i32

  CogRadius* = 500_000'i32
  BallRadius* = 220_000'i32
  SlideRadius* = 900_000'i32

  # ---- movement -------------------------------------------------------------
  Accel* = 25_000'i32          ## um/tick of speed added per tick.
  IdleDragNum* = 96'i32        ## v -= v*96/1024 with no direction held.
  BaseSpeed* = 250_000'i32     ## 6.0 m/s
  SprintSpeed* = 337_500'i32   ## 8.1 m/s
  DribbleSpeed* = 200_000'i32  ## 4.8 m/s
  KeeperSpeed* = 229_000'i32   ## 5.5 m/s
  TiredSpeedPct* = 85'i32
  TiredStamina* = 200'i32
  ExhaustedStamina* = 50'i32
  StaminaMax* = 1000'i32
  StaminaDrain* = 6'i32
  StaminaRecover* = 2'i32

  # ---- ball -----------------------------------------------------------------
  BallDragNum* = 7'i32         ## v -= v*7/1024 per tick (rolling friction).
  BallMaxSpeed* = 1_333_333'i32  ## 32 m/s
  Gravity* = 4_340'i32         ## um/tick^2
  AirApex* = 4_000_000'i32     ## high-pass apex height, um.
  GroundZ* = 400_000'i32       ## below this a flying ball is live again.
  ShortPassSpeed* = 583_333'i32  ## 14 m/s
  LongPassSpeed* = 916_666'i32   ## 22 m/s
  HighPassSpeed* = 750_000'i32   ## 18 m/s
  ShotSpeed* = 1_083_333'i32     ## 26 m/s
  ShortPassRange* = 25_000_000'i32
  LongPassRange* = 45_000_000'i32
  HighPassRange* = 40_000_000'i32
  PassLeadTicks* = 12'i32
  ControlRadius* = 1_100_000'i32
  ControlSpeed* = 750_000'i32
    ## The ball's ground speed at or below which a cog TAKES it rather than
    ## deflecting off it: 18 m/s. The design note pinned 12 m/s, which is BELOW
    ## the 14 m/s short pass — so no pass could ever be received on arrival and
    ## the certification episode finished 0-0 with one shot in a minute, every
    ## pass ricocheting off its receiver. 18 m/s draws the line where football
    ## draws it: you can control a pass (short 14, high 18), you cannot control
    ## a shot (26) or a long ball at full pace (22).
  DeflectPct* = 45'i32
  DribbleOffset* = 700_000'i32       ## carried-ball offset, no mode set.
  DribbleOffsetOff* = 900_000'i32
  DribbleOffsetOn* = 550_000'i32
  CogRestitutionPct* = 20'i32
  PostRestitutionPct* = 70'i32
  KeeperCatchRadius* = 1_500_000'i32
  KeeperCatchSpeed* = 750_000'i32
  KeeperParryPct* = 60'i32
  KeeperParryCap* = 500_000'i32
  TackleKnockSpeed* = 250_000'i32
  SlideSpeed* = 400_000'i32
  SlideTicks* = 12'i32
  GroundedAfterSlide* = 24'i32
  GroundedAfterFoul* = 48'i32
  PassCooldownTicks* = 12'i32
  ShotCooldownTicks* = 18'i32

  Substeps* = 4
  CogsPerTeam* = 11
  CogCount* = 22
  SeatCount* = 8
  TeamCount* = 2

  # ---- match shape ----------------------------------------------------------
  DefaultMaxTicks* = 5760      ## 240 s = 4:00 at 24 Hz.
  DefaultHalfTicks* = 2880     ## half-time.
  DefaultTurnTicks* = 240      ## 10.0 s of sim time per decision turn.
  DefaultTurnBudgetMs* = 10000
  DefaultAttempt1Ms* = 6000
  DefaultRetryMs* = 3000
  DefaultTurnSpacingMs* = 18000
  DefaultWallClockBudgetSeconds* = 690
  DefaultLobbyJoinTimeoutTicks* = 1440   ## 60 s of lobby ticks.
  DefaultStartWaitTicks* = 24
  DefaultGameOverTicks* = 360
  DefaultMercyGoalDiff* = 5
  DefaultRestartTicks* = 36    ## 1.5 s dead-ball phase.
  DefaultStalemateTicks* = 480 ## 20 s parked ball -> neutral drop.
  StalemateBox* = 2_000_000'i32
  RestartClearRadius* = 5_000_000'i32
  RestartTakerOffset* = 800_000'i32
  AssistWindowTicks* = 144'i32
  PassWindowTicks* = 144'i32
  TouchThrottleTicks* = 8

  DefaultSeed* = 0x6F0BA11
    ## The compiled-in default seed, and the "nobody chose a seed" sentinel a
    ## hosted variant config carries when it pins nothing (src/grf_football.nim).
    ## Deliberately NOT 679961: that is the certification fixture's seed, and a
    ## fixture seed must be a real pin.
  DefaultMinPlayers* = SeatCount
  MaxPlayers* = SeatCount
  DefaultMaxGames* = 1
  DefaultModel* = "claude-haiku-4-5-20251001"
  DefaultMaxOutputTokens* = 900

  # ---- reply caps (runes, never bytes) --------------------------------------
  MaxNoteRunes* = 160
  MaxSayRunes* = 48
  MaxPolicyRunes* = 48
  MaxDetailRunes* = 200
  MaxDirectiveRecordRunes* = 900
  MaxPromptRunes* = 4000
  MaxCogIdRunes* = 8

  AimBradsTurn* = 256          ## brads per full turn; ctf's convention.

  WebSocketPath* = "/player"
  GlobalWebSocketPath* = "/global"
  ReplayWebSocketPath* = "/replay"

type
  GrfFootballError* = object of ValueError

  Team* = enum
    ## Red defends x = PitchXMin and attacks +x; Blue mirrors it. Ordinals are
    ## wire format (flatty stores them positionally in replay keyframes):
    ## APPEND new members, never insert. The two keys are `red`/`blue` because
    ## those are the team keys the inherited `client/chrome_common.js` already
    ## knows, and that file is copied byte for byte.
    Red
    Blue

  GamePhase* = enum
    Lobby
    Playing
    GameOver

  RestartKind* = enum
    ## The dead-ball phase in progress. `rkNone` is live play.
    rkNone
    rkKickoff
    rkThrowIn
    rkCorner
    rkGoalKick
    rkFreeKick
    rkDrop

  EndRule* = enum
    ## The detail behind `results.reason`; see docs/RULES.md §End conditions.
    erFullTime
    erMercy
    erWallClock
    erSimFault
    erHostError

  EndReason* = enum
    reasonComplete
    reasonDeadline
    reasonFault

  Role* = enum
    roleStriker = "striker"
    roleWinger = "winger"
    rolePlaymaker = "playmaker"
    roleAnchor = "anchor"

  Intent* = enum
    inPress = "press"
    inHoldShape = "hold_shape"
    inMakeRun = "make_run"
    inSupport = "support"
    inDropDeep = "drop_deep"
    inCarry = "carry"
    inSwitchPlay = "switch_play"
    inShadow = "shadow"

  OnBall* = enum
    obShoot = "shoot"
    obPassShort = "pass_short"
    obPassLong = "pass_long"
    obPassHigh = "pass_high"
    obDribble = "dribble"
    obHold = "hold"

  SprintMode* = enum
    spAuto = "auto"
    spAlways = "always"
    spNever = "never"

  TackleMode* = enum
    tkAuto = "auto"
    tkNever = "never"

  DirectiveSource* = enum
    dsScripted
    dsLlm
    dsFallback

  PolicyKind* = enum
    pkScripted
    pkLlm

  CogOrder* = object
    ## One shirt's order for one decision turn. Targets are world micrometres,
    ## already clamped into the pitch by the parser.
    role*: Role
    intent*: Intent
    targetX*, targetY*: int32
    onBall*: OnBall
    passTo*: int32             ## cog index 0..21, -1 = none.
    sprint*: SprintMode
    tackle*: TackleMode
    say*: string               ## <= MaxSayRunes runes.

  Directive* = object
    ## A seat's active order. NEVER mixed into gameHash (ctf's rule for
    ## damagePops/skin): nothing a coach says can move the chain.
    turn*: int32
    half*: int32
    source*: DirectiveSource
    note*: string              ## <= MaxNoteRunes runes.
    latencyMs*: int32
    cog*: CogOrder

  Cog* = object
    ## One footballer. All positions/velocities are micrometres (um/tick).
    x*, y*: int32
    vx*, vy*: int32
    dir*: int32                ## last held direction nibble, 0..8.
    sprinting*: bool
    dribbling*: bool
    stamina*: int32
    slideTicks*: int32
    groundedTicks*: int32
    passCooldown*: int32
    shotCooldown*: int32
    slideDirX*, slideDirY*: int32   ## Q12 unit vector of the current slide.
    slideTouchedBall*: bool
    team*: int32               ## 0 = Red, 1 = Blue.
    shirt*: int32              ## 1..11.
    seat*: int32               ## seat index, -1 for a built-in AI shirt.
    distanceUm*: int64         ## odometer; analysis only, not hashed.

  Ball* = object
    x*, y*: int32
    vx*, vy*: int32
    z*, vz*: int32             ## height and vertical speed, um and um/tick.
    controller*: int32         ## cog index in possession, -1 = loose.
    dead*: bool                ## true during a restart (the ball may not move).

  Touch* = object
    ## Bookkeeping for assists, passes and saves; hashed (restarts read it).
    cog*: int32                ## -1 = nobody has touched the ball yet.
    team*: int32
    tick*: int32

  PassRecord* = object
    team*: int32
    cog*: int32
    tick*: int32
    target*: int32

  CogStats* = object
    goals*: int32
    assists*: int32
    passes*: int32
    passesCompleted*: int32
    interceptions*: int32
    shots*: int32
    shotsOnTarget*: int32
    tackles*: int32
    fouls*: int32

  TeamStats* = object
    goals*: int32
    shots*: int32
    shotsOnTarget*: int32
    saves*: int32
    possessionTicks*: int32
    passes*: int32
    tackles*: int32

  SeatStats* = object
    llmTurns*: int32
    fallbackTurns*: int32

  RewardAccount* = object
    address*: string
    slotIndex*: int32
    team*: Team
    hasSeat*: bool
    won*: bool
    abandoned*: bool
    reward*: int32
    goals*: int32

  PlayerSlotConfig* = object
    name*: string
    token*: string
    team*: Team
    hasTeam*: bool

  Player* = object
    ## One CONNECTION. Eight per match; each drives exactly one shirt.
    address*: string           ## the real policy name (spectator side only).
    joinOrder*: int32
    seat*: int32
    team*: Team
    shirt*: int32
    policyLabel*: string       ## <= MaxPolicyRunes runes, from `register`.
    policyKind*: PolicyKind
    baseline*: string          ## scripted baseline name, "" for an LLM seat.
    registered*: bool
    reward*: int32

  SimEventKind* = enum
    ## Tier-2 analysis event channel (the Logs substrate). Analysis-only:
    ## never enters gameHash.
    TouchEvent
    Pass
    Shot
    Save
    Goal
    Post
    Tackle
    Foul
    Out
    Restart
    Drop
    HalfTime
    PhaseChange
    DirectiveEvent

  SimEvent* = object
    tick*: int
    kind*: SimEventKind
    source*: int               ## acting cog index, -1 = n/a.
    target*: int               ## affected cog index, -1 = n/a.
    team*: int                 ## acting team, -1 = n/a.
    amount*: int
    x*, y*: int32              ## world micrometres.
    speed*: int32              ## micrometres per tick.
    content*: string

  GameConfig* = object
    ## Every field a coworld variant may set. `sim_config.update` reads them;
    ## `configJson` echoes them into the replay header so playback re-derives
    ## the identical world. Adding a field here means adding it to
    ## `game.config_schema` in coworld_manifest_template.json in the same
    ## commit (tests/test_manifest.nim enforces it).
    seed*: int
    speed*: int
    numAgents*: int
    minPlayers*: int
    startWaitTicks*: int
    lobbyJoinTimeoutTicks*: int
    gameOverTicks*: int
    maxTicks*: int
    halfTicks*: int
    maxGames*: int
    turnTicks*: int
    turnBudgetMs*: int
    attempt1Ms*: int
    retryMs*: int
    turnSpacingMs*: int
    wallClockBudgetSeconds*: int
    mercyGoalDiff*: int
    restartTicks*: int
    stalemateTicks*: int
    fastMode*: bool
    showPlayerLabels*: bool
    closedRoster*: bool
    model*: string
    maxOutputTokens*: int
    baseSpeed*: int
    sprintSpeed*: int
    shotSpeed*: int
    shortPassSpeed*: int
    longPassSpeed*: int
    slots*: seq[PlayerSlotConfig]

  TrailPoint* = object
    x*, y*: int32
    z*: int32
    tick*: int32
    team*: int32               ## last toucher's team, -1 = loose.

  ArcFx* = object
    ## A pass arc, a shot streak or a save/post burst. Cosmetic only.
    x0*, y0*, x1*, y1*: int32
    tick*: int32
    team*: int32
    kind*: int32               ## 0 = pass, 1 = shot, 2 = burst.

  GoalFx* = object
    tick*: int32
    team*: int32

  FeedLine* = object
    tick*: int32
    kind*: string
    team*: int32
    text*: string

  SimServer* = object
    ## Flatty-serialized POSITIONALLY into replay keyframes. Append only.
    config*: GameConfig
    players*: seq[Player]
    rewardAccounts*: seq[RewardAccount]
    cogs*: array[CogCount, Cog]
    ball*: Ball
    cogStats*: array[CogCount, CogStats]
    teamStats*: array[Team, TeamStats]
    seatStats*: array[SeatCount, SeatStats]
    rng*: Rand
    rngDraws*: int32
      ## How many draws have been taken from `rng`. HASHED: `Rand`'s own state
      ## is private to std/random, so this counter is the only way the chain
      ## can see a stream that has drifted. Every draw goes through
      ## `sim.draw`, which is the only place `rng` is touched.
    nextJoinOrder*: int32
    tickCount*: int
    gameStartTick*: int
    startWaitTimer*: int
    lobbyWaitTimer*: int
    phase*: GamePhase
    winner*: Team
    isDraw*: bool
    gameOverTimer*: int
    endReason*: EndReason
    endRule*: EndRule
    ended*: bool
    half*: int32
    restartKind*: RestartKind
    restartTeam*: int32
    restartTaker*: int32
    restartTicks*: int32
    restartX*, restartY*: int32
    stalemateTicks*: int32
    anchorX*, anchorY*: int32
    lastTouch*: Touch
    prevTouch*: Touch
    pendingPass*: PassRecord
    pendingShotTeam*: int32
    pendingShotCog*: int32
    pendingShotTick*: int32
    needsReregister*: bool
    ## --- outside the hash from here on ---
    activeDirective*: array[SeatCount, Directive]
    hasDirective*: array[SeatCount, bool]
    trail*: seq[TrailPoint]    ## cosmetic ball trail; never hashed.
    arcs*: seq[ArcFx]          ## pass/shot arcs and bursts; never hashed.
    goalFx*: seq[GoalFx]       ## goal celebrations; never hashed.
    feed*: seq[FeedLine]       ## broadcast match-feed rows; never hashed.
    gameEventLoggingEnabled*: bool
    collectEvents*: bool
    events*: seq[SimEvent]
    lastLobbyPlayersLogged*: int
    lastLobbyNeededLogged*: int
    lastLobbySecondsLogged*: int
    ## The most recent goal, kept for the broadcast channel. Set inside the
    ## hashed step, so the viewer re-derives it identically, but NOT hashed:
    ## the kickoff reset clears `lastTouch`, and the feed still has to be able
    ## to say who scored.
    lastGoalTick*: int32
    lastGoalTeam*: int32
    lastGoalBy*: int32
    lastGoalAssist*: int32
    lastGoalSpeed*: int32
    lastDropTick*: int32
    lastRestartTick*: int32
    lastHalfTimeTick*: int32

const
  RedColor* = rgba(224, 82, 58, 255)     ## team vermillion; matches rig_real/red.
  BlueColor* = rgba(63, 124, 196, 255)   ## team cerulean; matches rig_real/blue.
  TurfDark* = rgba(38, 86, 46, 255)
  TurfLight* = rgba(46, 100, 54, 255)
  LineColor* = rgba(232, 240, 230, 235)
  BallColor* = rgba(244, 244, 238, 255)

  DirVecQ12*: array[9, tuple[x, y: int32]] = [
    (0'i32, 0'i32),          ## 0 = no direction
    (0'i32, -4096'i32),      ## 1 = N
    (2896'i32, -2896'i32),   ## 2 = NE
    (4096'i32, 0'i32),       ## 3 = E
    (2896'i32, 2896'i32),    ## 4 = SE
    (0'i32, 4096'i32),       ## 5 = S
    (-2896'i32, 2896'i32),   ## 6 = SW
    (-4096'i32, 0'i32),      ## 7 = W
    (-2896'i32, -2896'i32)]  ## 8 = NW
    ## The eight gfootball compass directions as Q12 unit vectors, in SCREEN
    ## convention (y points down, so N is -y). Index 0 is release_direction.

  DirBrads*: array[9, int32] = [0'i32, 64, 32, 0, 224, 192, 160, 128, 96]
    ## The same eight directions as brad angles (0 = east, CCW on screen).

  ShirtAnchorX*: array[CogsPerTeam, int32] = [
    ## Formation anchors for RED in world micrometres, indexed by shirt-1.
    ## Blue mirrors in x. Design note §Kickoff: 4-3-3.
    6_000_000'i32,    ## 1  keeper      (-39, 0)
    15_000_000'i32,   ## 2  right back  (-30, -16)
    15_000_000'i32,   ## 3  left back   (-30, +16)
    14_000_000'i32,   ## 4  centre back (-31, +6)
    14_000_000'i32,   ## 5  centre back (-31, -6)
    23_000_000'i32,   ## 6  anchor      (-22, 0)
    39_000_000'i32,   ## 7  right wing  (-6, -19)
    31_000_000'i32,   ## 8  centre mid  (-14, +9)
    41_000_000'i32,   ## 9  striker     (-4, 0)
    33_000_000'i32,   ## 10 playmaker   (-12, -5)
    39_000_000'i32]   ## 11 left wing   (-6, +19)

  ShirtAnchorY*: array[CogsPerTeam, int32] = [
    30_000_000'i32,   ## 1
    14_000_000'i32,   ## 2
    46_000_000'i32,   ## 3
    36_000_000'i32,   ## 4
    24_000_000'i32,   ## 5
    30_000_000'i32,   ## 6
    11_000_000'i32,   ## 7
    39_000_000'i32,   ## 8
    30_000_000'i32,   ## 9
    25_000_000'i32,   ## 10
    49_000_000'i32]   ## 11

  SeatShirt*: array[SeatCount, int32] = [10'i32, 10, 9, 9, 7, 7, 6, 6]
    ## Seat -> shirt. Seat parity IS the team (ctf's `teamForSlot` deals
    ## `slot mod teams`), so seat 0 is RED-10, seat 1 BLUE-10, and so on.

  SeatRole*: array[SeatCount, Role] = [
    rolePlaymaker, rolePlaymaker, roleStriker, roleStriker,
    roleWinger, roleWinger, roleAnchor, roleAnchor]

  DropSpots*: array[4, tuple[x, y: int32]] = [
    (24_000_000'i32, 16_500_000'i32),
    (24_000_000'i32, 43_500_000'i32),
    (66_000_000'i32, 16_500_000'i32),
    (66_000_000'i32, 43_500_000'i32)]
    ## Neutral-drop spots, (+-21 m, +-13.5 m) in view coordinates.

proc teamText*(team: Team): string {.inline.} =
  case team
  of Red: "red"
  of Blue: "blue"

proc teamPrefix*(team: Team): string {.inline.} =
  case team
  of Red: "RED"
  of Blue: "BLUE"

proc cogId*(index: int): string {.inline.} =
  ## The in-game shirt name: `RED-1`..`RED-11`, `BLUE-1`..`BLUE-11`. This is
  ## the ONLY cog identity a policy ever sees.
  let team = if index < CogsPerTeam: Red else: Blue
  teamPrefix(team) & "-" & $((index mod CogsPerTeam) + 1)

proc teamOfCog*(index: int): Team {.inline.} =
  if index < CogsPerTeam: Red else: Blue

proc firstCogOf*(team: Team): int {.inline.} =
  ord(team) * CogsPerTeam

proc cogOfShirt*(team: Team, shirt: int): int {.inline.} =
  ## Shirt 1..11 -> cog index. Out-of-range shirts clamp, so no caller can
  ## index outside the array.
  firstCogOf(team) + clamp(shirt, 1, CogsPerTeam) - 1

proc teamOfSeat*(seat: int): Team {.inline.} =
  if (seat and 1) == 0: Red else: Blue

proc cogOfSeat*(seat: int): int {.inline.} =
  ## The one shirt a seat commands, derived from the seat index alone.
  if seat < 0 or seat >= SeatCount:
    -1
  else:
    cogOfShirt(teamOfSeat(seat), int(SeatShirt[seat]))

proc attackDir*(team: Team): int32 {.inline.} =
  ## +1 when the team attacks +x, -1 when it attacks -x.
  if team == Red: 1'i32 else: -1'i32

proc ownGoalX*(team: Team): int32 {.inline.} =
  if team == Red: PitchXMin else: PitchXMax

proc targetGoalX*(team: Team): int32 {.inline.} =
  if team == Red: PitchXMax else: PitchXMin

proc other*(team: Team): Team {.inline.} =
  if team == Red: Blue else: Red

proc anchorXFor*(team: Team, shirt: int): int32 {.inline.} =
  let s = clamp(shirt, 1, CogsPerTeam)
  if team == Red: ShirtAnchorX[s - 1] else: WorldW - ShirtAnchorX[s - 1]

proc anchorYFor*(team: Team, shirt: int): int32 {.inline.} =
  ShirtAnchorY[clamp(shirt, 1, CogsPerTeam) - 1]

proc roleText*(role: Role): string {.inline.} = $role
proc intentText*(intent: Intent): string {.inline.} = $intent
proc onBallText*(value: OnBall): string {.inline.} = $value
proc sprintText*(value: SprintMode): string {.inline.} = $value
proc tackleText*(value: TackleMode): string {.inline.} = $value

proc restartText*(kind: RestartKind): string {.inline.} =
  case kind
  of rkNone: "playing"
  of rkKickoff: "kickoff"
  of rkThrowIn: "throw_in"
  of rkCorner: "corner"
  of rkGoalKick: "goal_kick"
  of rkFreeKick: "free_kick"
  of rkDrop: "drop"

proc sourceText*(source: DirectiveSource): string {.inline.} =
  case source
  of dsScripted: "scripted"
  of dsLlm: "llm"
  of dsFallback: "fallback"

proc reasonText*(reason: EndReason): string {.inline.} =
  case reason
  of reasonComplete: "complete"
  of reasonDeadline: "deadline"
  of reasonFault: "fault"

proc endRuleText*(rule: EndRule): string {.inline.} =
  case rule
  of erFullTime: "full_time"
  of erMercy: "mercy"
  of erWallClock: "wall_clock"
  of erSimFault: "sim_fault"
  of erHostError: "host_error"

proc reasonOfText*(text: string): EndReason {.inline.} =
  ## The inverse of `reasonText`. A wall-clock stop is a WALL-CLOCK FACT: it
  ## cannot be re-derived from sim state, so it travels as a replay record and
  ## is re-applied on playback through the same `finishGame` the server called.
  case text
  of "deadline": reasonDeadline
  of "fault": reasonFault
  else: reasonComplete

proc endRuleOfText*(text: string): EndRule {.inline.} =
  case text
  of "mercy": erMercy
  of "wall_clock": erWallClock
  of "sim_fault": erSimFault
  of "host_error": erHostError
  else: erFullTime

proc policyKindText*(kind: PolicyKind): string {.inline.} =
  case kind
  of pkScripted: "scripted"
  of pkLlm: "llm"

proc policyName*(address: string): string =
  ## The policy identity behind a connection address: the hosted runtime
  ## appends a per-seat " (N)" suffix to the same policy's several connections,
  ## and the join path turns spaces into underscores. Kept from ctf.
  result = address
  var cut = result.len
  var i = result.len - 1
  while i >= 0 and result[i] in {' ', '\t'}:
    dec i
  if i >= 0 and result[i] == ')':
    var j = i - 1
    while j >= 0 and result[j] in {'0' .. '9'}:
      dec j
    if j >= 0 and j < i - 1 and result[j] == '(':
      dec j
      while j >= 0 and result[j] in {' ', '_', '\t'}:
        dec j
      cut = j + 1
  if cut < result.len:
    result = result[0 ..< cut]

proc mapPxX*(x: int32): int {.inline.} = int(x) div MapScale
proc mapPxY*(y: int32): int {.inline.} = int(y) div MapScale

# --------------------------------------------------------------------------
# The 19-action byte. One uint8 per cog per tick: the same byte ctf records,
# the same byte the wasm viewer replays. Only the INTERPRETATION changes.
# --------------------------------------------------------------------------

proc actionDir*(action: uint8): int32 {.inline.} =
  ## Bits 0-3: 0 = none (release_direction / idle), 1..8 = N,NE,E,SE,S,SW,W,NW.
  ## 9..15 are illegal and read as 0.
  let d = int32(action and 0x0F'u8)
  if d > 8: 0'i32 else: d

proc actionCode*(action: uint8): int32 {.inline.} =
  ## Bits 4-6: 0 none, 1 short_pass, 2 long_pass, 3 high_pass, 4 shot,
  ## 5 slide, 6 dribble_on, 7 dribble_off.
  int32((action shr 4) and 0x07'u8)

proc actionSprint*(action: uint8): bool {.inline.} =
  (action and 0x80'u8) != 0'u8

proc encodeAction*(dir, code: int32, sprint: bool): uint8 {.inline.} =
  ## The inverse of the three readers above; illegal inputs clamp rather than
  ## raise, so no caller can encode a byte the decoders would reinterpret.
  let
    d = uint8(clamp(dir, 0'i32, 8'i32))
    c = uint8(clamp(code, 0'i32, 7'i32))
  d or (c shl 4) or (if sprint: 0x80'u8 else: 0'u8)
