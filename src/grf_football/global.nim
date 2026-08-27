## The board renderer: pitch, cogs, ball, trail, play arcs, the goal
## celebration and the seat rings, composed as Sprite v1 sprite/object
## messages.
##
## This replaces ctf's `global.nim` (7 700 lines of fog-of-war, vision cones,
## first-person raycasting, killfeed art and weapon sprites). Football is a
## perfect-information sport, so there is NO fog and no first-person inset: the
## two builders differ only in the self marker and the seat's own-alias marker.
##
## Floats are legal here — rendering never enters `gameHash`, exactly as in
## ctf. The turf bake lives here rather than in `pitch.nim` because that module
## sits inside the float-free grep guard and pixie is a float API.

import
  std/[math, tables],
  pixie,
  bitworld/spriteprotocol,
  sim, labels, rig_art

const
  BoardScale* = 2
    ## Board pixels per LOGICAL map pixel. The chrome reports this as `bs` and
    ## converts board <-> world with it.
  BoardW* = MapWidth * BoardScale
  BoardH* = MapHeight * BoardScale
  MapLayerId* = 0
  MapBandRows = 64 * BoardScale

  # ---- sprite ids -----------------------------------------------------------
  MapBandSpriteBase = 30
  MaxMapBands = 32
  BallSpriteId = 70
  BallShadowSpriteId = 71
  RigSpriteBase = 100          ## 2 liveries x RigSteps
  ChipSpriteBase = 140         ## 2 liveries x 11 shirts
  RingSpriteBase = 170         ## 2 liveries
  TrailSpriteBase = 200        ## 3 tints x TrailStages
  ArcSpriteBase = 240          ## 3 tints (red / blue / neutral)
  ConfettiSpriteBase = 280     ## one per team
  GoalFlashSpriteId = 290
  SelfMarkerSpriteId = 292
  OwnSeatSpriteId = 294
  BroadcastChromeSpriteId* = 4090
    ## The reserved 1x1 sprite whose LABEL carries the broadcast chrome JSON.
    ## Kept from ctf, id and all, so the shared client code needs no change.

  # ---- object ids -----------------------------------------------------------
  MapBandObjectBase = 30
  CogObjectBase = 1000
  ChipObjectBase = 1040
  RingObjectBase = 1080
  BallObjectId = 1300
  BallShadowObjectId = 1301
  SelfMarkerObjectId = 1310
  OwnSeatObjectId = 1320
  TrailObjectBase = 2000
  TrailSlots = 40
  ArcObjectBase = 2100
  ArcSlots = 8
  ArcDots = 10
  ConfettiObjectBase = 2200
  ConfettiSlots = 120
  GoalFlashObjectId = 2400

  TrailStages = 8
  ArcFxTicks* = 12
  GoalFxTicks* = 45
  GoalFlashPx = 240

  BoardObjectPools: array[6, tuple[name: string, base, width: int]] = [
    ("map", MapBandObjectBase, MaxMapBands),
    ("cogs", CogObjectBase, CogCount),
    ("chips", ChipObjectBase, CogCount),
    ("rings", RingObjectBase, CogCount),
    ("trail", TrailObjectBase, TrailSlots),
    ("confetti", ConfettiObjectBase, ConfettiSlots)
  ]

type
  SpriteDefinition = ref object
    spriteId: int
    width, height: int
    label: string
    pixels: seq[uint8]

  GlobalViewerState* = object
    initialized*: bool
    mouseX*, mouseY*, mouseLayer*: int
    mouseDown*: bool
    clickPending*: bool
    selectedJoinOrder*: int
    povJoinOrder*: int
    povSelectPending*: int
    scrubbingReplay*: bool
    replaySeekTick*: int
    replayCommands*: seq[char]
    momentumSent*: bool
    fpMapSent*: bool
    spriteDefs: seq[SpriteDefinition]

  PlayerViewerState* = ref object
    initialized*: bool
    sentPlacements*: seq[array[12, uint8]]
    spriteDefs: seq[SpriteDefinition]

proc boardObjectPoolName*(objectId: int): string =
  ## Names the fixed object pool an object id belongs to, for traffic metrics.
  for (name, base, width) in BoardObjectPools:
    if objectId >= base and objectId < base + width:
      return name
  "core"

proc boardRenderScaleFor*(mapWidth, mapHeight: int): int =
  ## The board's supersample factor. Fixed here: grf-football has exactly one
  ## board and it is small enough to render at BoardScale on every target.
  discard mapWidth
  discard mapHeight
  BoardScale

proc initGlobalViewerState*(): GlobalViewerState =
  result.mouseLayer = MapLayerId
  result.selectedJoinOrder = -1
  result.povJoinOrder = -1
  result.povSelectPending = -2   ## -2 = no request; -1 = clear; >= 0 = slot.
  result.replaySeekTick = -1
  result.replayCommands = @[]

proc initPlayerViewerState*(): PlayerViewerState =
  new(result)

# --------------------------------------------------------------------------
# Client -> server messages
# --------------------------------------------------------------------------

proc applyGlobalViewerMessage*(state: var GlobalViewerState, message: string) =
  ## Applies one or more global protocol client messages. Whole-string
  ## commands (`s:<tick>`, `v:<slot>`) are intercepted before the legacy
  ## char-by-char transport path, so a multi-digit tick is never mangled into
  ## speed keystrokes. Kept from ctf.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientMouseMoveMessage:
      state.mouseX = item.x
      state.mouseY = item.y
      state.mouseLayer = if item.hasLayer: item.layer else: MapLayerId
    of SpriteClientMouseButtonMessage:
      if item.button == 0x01'u8:
        state.mouseDown = item.down
        if state.mouseDown:
          state.clickPending = true
        else:
          state.scrubbingReplay = false
    of SpriteClientChatMessage:
      if item.text.len > 2 and item.text[0] == 's' and item.text[1] == ':':
        var tick = 0
        var ok = item.text.len > 2
        for i in 2 ..< item.text.len:
          if item.text[i] notin {'0' .. '9'}:
            ok = false
            break
          tick = tick * 10 + (ord(item.text[i]) - ord('0'))
        if ok:
          state.replaySeekTick = tick
      elif item.text.len > 2 and item.text[0] == 'v' and item.text[1] == ':':
        var slot = 0
        var ok = true
        var negative = false
        for i in 2 ..< item.text.len:
          if i == 2 and item.text[i] == '-':
            negative = true
            continue
          if item.text[i] notin {'0' .. '9'}:
            ok = false
            break
          slot = slot * 10 + (ord(item.text[i]) - ord('0'))
        if ok:
          state.povSelectPending = if negative: -slot else: slot
      else:
        for ch in item.text:
          state.replayCommands.add(ch)
    of SpriteClientInputMessage, SpriteClientReadyMessage,
        SpriteClientDebugSpriteMessage:
      discard

proc applyPlayerViewerMessage*(
  state: var PlayerViewerState,
  message: string,
  inputMask: var uint8,
  pressedMask: var uint8,
  chatText: var string
) =
  ## A seat sends NO inputs (the server computes every mask), so the input
  ## bits are read and dropped. Its ONE chat message is its registration; the
  ## server intercepts it and never writes it to the replay chat stream.
  ## ctf's 0x86 debug-sprite channel is deleted rather than left dangling.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      chatText.add(item.text)
    of SpriteClientInputMessage:
      pressedMask = 0
      inputMask = 0
    else:
      discard
  discard state

# --------------------------------------------------------------------------
# Packet plumbing (kept from ctf: generic, sprite-protocol level)
# --------------------------------------------------------------------------

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one sprite-protocol packet into WS-frame-sized chunks at MESSAGE
  ## boundaries. The hosted replay closes any frame over 1 MiB (1009), and the
  ## client accumulates sprite/object state across binary messages, so N
  ## frames are equivalent to one — as long as no frame is cut mid-message.
  result = @[]
  if packet.len == 0:
    return
  var
    offset = 0
    chunkStart = 0
  while offset < packet.len:
    let msgStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      let clen = packet.readU32(offset + 6)
      offset += 10 + clen
      let llen = packet.readU16(offset)
      offset += 2 + llen
    of 0x02: offset += 11
    of 0x03: offset += 2
    of 0x04: discard
    of 0x05: offset += 5
    of 0x06: offset += 3
    else:
      break
    if offset - chunkStart > maxBytes and msgStart > chunkStart:
      result.add(packet[chunkStart ..< msgStart])
      chunkStart = msgStart
  if chunkStart < packet.len:
    result.add(packet[chunkStart ..< packet.len])

proc stripSpritePixels*(packet: seq[uint8], keepLabel = ""): seq[uint8] =
  ## Rewrites one packet for a Sprites Off (0x87) client: sprite definitions
  ## keep id, dimensions and label but ship a zero-length pixel payload.
  result = newSeqOfCap[uint8](packet.len)
  var offset = 0
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      let compressedLen = packet.readU32(offset + 6)
      let labelStart = offset + 10 + compressedLen
      let labelLen = packet.readU16(labelStart)
      let messageEnd = labelStart + 2 + labelLen
      var label = newString(labelLen)
      for i in 0 ..< labelLen:
        label[i] = char(packet[labelStart + 2 + i])
      if keepLabel.len > 0 and label == keepLabel:
        for i in messageStart ..< messageEnd:
          result.add(packet[i])
      else:
        for i in messageStart ..< offset + 6:
          result.add(packet[i])
        result.addU32(0)
        for i in labelStart ..< messageEnd:
          result.add(packet[i])
      offset = messageEnd
    of 0x02, 0x03, 0x04, 0x05, 0x06:
      offset += (
        case messageType
        of 0x02: 11
        of 0x03: 2
        of 0x05: 5
        of 0x06: 3
        else: 0
      )
      for i in messageStart ..< offset:
        result.add(packet[i])
    else:
      for i in messageStart ..< packet.len:
        result.add(packet[i])
      break

proc dedupObjectPlacements*(
  packet: seq[uint8],
  sentPlacements: var seq[array[12, uint8]]
): seq[uint8] =
  ## Drops Define Object messages whose full payload matches what this viewer
  ## already holds. The protocol is retained-mode, so re-sending an identical
  ## placement is pure wire noise. Kept from ctf.
  result = newSeqOfCap[uint8](packet.len)
  if sentPlacements.len == 0:
    sentPlacements.setLen(65536)
  var
    offset = 0
    keepStart = 0
  template flushKept(upTo: int) =
    if upTo > keepStart:
      let start = result.len
      result.setLen(start + upTo - keepStart)
      copyMem(addr result[start], unsafeAddr packet[keepStart],
        upTo - keepStart)
  while offset < packet.len:
    let messageStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:
      offset += 10 + packet.readU32(offset + 6)
      offset += 2 + packet.readU16(offset)
    of 0x02:
      var payload: array[12, uint8]
      copyMem(addr payload[0], unsafeAddr packet[offset], 11)
      payload[11] = 1
      offset += 11
      let objectId = int(payload[0]) or (int(payload[1]) shl 8)
      if sentPlacements[objectId] == payload:
        flushKept(messageStart)
        keepStart = offset
      else:
        sentPlacements[objectId] = payload
    of 0x03:
      sentPlacements[packet.readU16(offset)][11] = 0
      offset += 2
    of 0x04:
      zeroMem(addr sentPlacements[0], sentPlacements.len * 12)
    of 0x05, 0x06:
      offset += (if messageType == 0x05: 5 else: 3)
    else:
      offset = packet.len
  flushKept(packet.len)

# --------------------------------------------------------------------------
# The turf bake
# --------------------------------------------------------------------------

var
  pitchBands: seq[seq[uint8]]
  pitchBandRows: seq[int]

proc worldToBoard*(x: int32): int {.inline.} =
  int((int64(x) * int64(BoardScale)) div int64(MapScale))

proc bakePitchImage*(): Image =
  ## Mown turf in two greens with 4 m stripes, painted white lines at 0.12 m,
  ## hatched goal nets with depth, advertising boards around the surround and a
  ## dark vignette. Baked once at startup with pixie — already a dependency,
  ## already how ctf bakes its board.
  result = newImage(BoardW, BoardH)
  let
    ctx = newContext(result)
    px = float32(BoardScale) / float32(MapScale)   ## board px per micrometre.
  proc bx(x: int32): float32 = float32(x) * px
  proc by(y: int32): float32 = float32(y) * px
  let stroke = max(2.0'f32, bx(120_000'i32))
  # The surround, then the advertising boards around it.
  ctx.fillStyle = rgba(18, 26, 20, 255)
  ctx.fillRect(rect(0, 0, float32(BoardW), float32(BoardH)))
  var adX = PitchXMin
  var band = 0
  while adX < PitchXMax:
    let w = min(6_000_000'i32, PitchXMax - adX)
    ctx.fillStyle =
      if band mod 3 == 0: rgba(184, 62, 48, 235)
      elif band mod 3 == 1: rgba(40, 66, 132, 235)
      else: rgba(214, 190, 96, 235)
    ctx.fillRect(rect(bx(adX), by(600_000'i32), bx(w), by(1_400_000'i32)))
    ctx.fillRect(rect(bx(adX), by(PitchYMax + 1_000_000'i32), bx(w),
      by(1_400_000'i32)))
    adX += w
    inc band
  # Mown stripes across the playing surface, 4 m wide.
  var stripe = 0
  var sx = PitchXMin
  while sx < PitchXMax:
    let w = min(4_000_000'i32, PitchXMax - sx)
    ctx.fillStyle = if stripe mod 2 == 0: TurfDark else: TurfLight
    ctx.fillRect(rect(bx(sx), by(PitchYMin), bx(w), by(PitchYMax - PitchYMin)))
    sx += w
    inc stripe
  # Goal boxes: darker turf behind each goal line, plus hatched netting.
  ctx.fillStyle = rgba(24, 52, 30, 255)
  ctx.fillRect(rect(bx(PitchXMin - GoalDepth), by(GoalYMin), bx(GoalDepth),
    by(GoalYMax - GoalYMin)))
  ctx.fillRect(rect(bx(PitchXMax), by(GoalYMin), bx(GoalDepth),
    by(GoalYMax - GoalYMin)))
  ctx.strokeStyle = rgba(226, 232, 226, 120)
  ctx.lineWidth = max(1.0'f32, stroke * 0.35)
  var netY = GoalYMin
  while netY <= GoalYMax:
    ctx.strokeSegment(segment(vec2(bx(PitchXMin - GoalDepth), by(netY)),
      vec2(bx(PitchXMin), by(netY))))
    ctx.strokeSegment(segment(vec2(bx(PitchXMax), by(netY)),
      vec2(bx(PitchXMax + GoalDepth), by(netY))))
    netY += 500_000'i32
  var netX = 0'i32
  while netX <= GoalDepth:
    ctx.strokeSegment(segment(vec2(bx(PitchXMin - GoalDepth + netX),
      by(GoalYMin)), vec2(bx(PitchXMin - GoalDepth + netX), by(GoalYMax))))
    ctx.strokeSegment(segment(vec2(bx(PitchXMax + netX), by(GoalYMin)),
      vec2(bx(PitchXMax + netX), by(GoalYMax))))
    netX += 500_000'i32
  # Painted lines.
  ctx.strokeStyle = LineColor
  ctx.lineWidth = stroke
  proc line(x0, y0, x1, y1: int32) =
    ctx.strokeSegment(segment(vec2(bx(x0), by(y0)), vec2(bx(x1), by(y1))))
  line(PitchXMin, PitchYMin, PitchXMax, PitchYMin)
  line(PitchXMin, PitchYMax, PitchXMax, PitchYMax)
  line(PitchXMin, PitchYMin, PitchXMin, PitchYMax)
  line(PitchXMax, PitchYMin, PitchXMax, PitchYMax)
  line(CentreX, PitchYMin, CentreX, PitchYMax)
  ctx.strokeEllipse(vec2(bx(CentreX), by(CentreY)),
    bx(CentreCircleR), bx(CentreCircleR))
  # Penalty and six-yard boxes, both ends.
  for endIndex in 0 .. 1:
    let
      isRed = endIndex == 0
      goalLine = if isRed: PitchXMin else: PitchXMax
      inward = if isRed: 1'i32 else: -1'i32
    for depthHalf in [(PenaltyDepth, PenaltyHalfH),
        (SixYardDepth, SixYardHalfH)]:
      let
        edge = goalLine + depthHalf[0] * inward
        yLo = CentreY - depthHalf[1]
        yHi = CentreY + depthHalf[1]
      line(edge, yLo, edge, yHi)
      line(goalLine, yLo, edge, yLo)
      line(goalLine, yHi, edge, yHi)
    # The penalty spot and the D.
    let spot = goalLine + 11_000_000'i32 * inward
    ctx.fillStyle = LineColor
    ctx.fillEllipse(vec2(bx(spot), by(CentreY)), stroke, stroke)
    ctx.strokeEllipse(vec2(bx(spot), by(CentreY)),
      bx(9_150_000'i32), bx(9_150_000'i32))
  # The centre spot and the four corner arcs.
  ctx.fillStyle = LineColor
  ctx.fillEllipse(vec2(bx(CentreX), by(CentreY)), stroke, stroke)
  for corner in [(PitchXMin, PitchYMin), (PitchXMin, PitchYMax),
      (PitchXMax, PitchYMin), (PitchXMax, PitchYMax)]:
    ctx.strokeEllipse(vec2(bx(corner[0]), by(corner[1])),
      bx(1_000_000'i32), bx(1_000_000'i32))
  # Goalposts.
  ctx.fillStyle = rgba(246, 248, 246, 255)
  for post in Posts:
    ctx.fillEllipse(vec2(bx(post.x), by(post.y)),
      max(2.0'f32, bx(PostRadius) * 2), max(2.0'f32, bx(PostRadius) * 2))
  # A dark vignette so the eye stays on the pitch.
  let vignette = newImage(BoardW, BoardH)
  let vctx = newContext(vignette)
  vctx.fillStyle = rgba(0, 0, 0, 70)
  vctx.fillRect(rect(0, 0, float32(BoardW), float32(BoardH)))
  vctx.fillStyle = rgba(0, 0, 0, 0)
  vctx.fillRect(rect(bx(PitchXMin) - 8, by(PitchYMin) - 8,
    bx(PitchXMax - PitchXMin) + 16, by(PitchYMax - PitchYMin) + 16))
  result.draw(vignette)

proc invalidateBoardMapCaches*() =
  ## Drops every process-wide cache derived from the board bake. Needed when
  ## the serve loop hot-switches replays.
  pitchBands = @[]
  pitchBandRows = @[]

proc ensurePitchBands() =
  if pitchBands.len > 0:
    return
  let image = bakePitchImage()
  var y = 0
  while y < BoardH:
    let rows = min(MapBandRows, BoardH - y)
    var band = newSeq[uint8](BoardW * rows * 4)
    for row in 0 ..< rows:
      for x in 0 ..< BoardW:
        let
          c = image.data[(y + row) * BoardW + x].rgba()
          o = (row * BoardW + x) * 4
        band[o] = c.r
        band[o + 1] = c.g
        band[o + 2] = c.b
        band[o + 3] = c.a
    pitchBands.add(band)
    pitchBandRows.add(rows)
    y += rows
  doAssert pitchBands.len <= MaxMapBands, "pitch band pool overflow"

proc warmBoardRenderCaches*(sim: SimServer) =
  ## Pre-bakes every process-wide render cache at server startup so the first
  ## viewer's init packet is assembled instantly. Without this the first
  ## connection pays the whole bake, which trips the coworld certifier's
  ## first-message timeout. Idempotent.
  discard sim
  ensurePitchBands()
  for team in Team:
    for step in 0 ..< RigSteps:
      discard rigPixels(team, step, BoardScale)
    for shirt in 1 .. CogsPerTeam:
      discard shirtChipPixels(team, shirt, BoardScale)
    discard seatRingPixels(team, BoardScale)
  discard ballPixels(BoardScale)
  discard ballShadowPixels(BoardScale)

# --------------------------------------------------------------------------
# Emission helpers
# --------------------------------------------------------------------------

proc addSpriteOnce(
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  spriteId, width, height: int,
  pixels: seq[uint8],
  label: string
) =
  ## Emits a sprite definition only when this viewer has not already been sent
  ## an identical one. Sprite definitions are the expensive half of the wire.
  for existing in defs:
    if existing.spriteId == spriteId:
      if existing.width == width and existing.height == height and
          existing.label == label and existing.pixels == pixels:
        return
      existing.width = width
      existing.height = height
      existing.label = label
      existing.pixels = pixels
      packet.addSprite(spriteId, width, height, pixels, label)
      return
  defs.add SpriteDefinition(spriteId: spriteId, width: width, height: height,
    label: label, pixels: pixels)
  packet.addSprite(spriteId, width, height, pixels, label)

proc rigSpriteId(team: Team, step: int): int {.inline.} =
  RigSpriteBase + ord(team) * RigSteps + step

proc chipSpriteId(team: Team, shirt: int): int {.inline.} =
  ChipSpriteBase + ord(team) * CogsPerTeam + clamp(shirt, 1, CogsPerTeam) - 1

proc trailTint(team: int32): int {.inline.} =
  if team < 0: 2 else: int(team)

proc trailSpriteId(team: int32, stage: int): int {.inline.} =
  TrailSpriteBase + trailTint(team) * TrailStages + stage

proc tintColour(team: int32, alpha: uint8): ColorRGBA =
  case trailTint(team)
  of 0: rgba(RedColor.r, RedColor.g, RedColor.b, alpha)
  of 1: rgba(BlueColor.r, BlueColor.g, BlueColor.b, alpha)
  else: rgba(238, 238, 226, alpha)

proc addBoardChrome(
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## Viewport, layers and the banded turf. Emitted once per viewer.
  ensurePitchBands()
  packet.addViewport(MapLayerId, BoardW, BoardH)
  packet.addLayer(MapLayerId, 0, SpriteLayerZoomableFlag)
  var y = 0
  for i, band in pitchBands:
    packet.addSpriteOnce(defs, MapBandSpriteBase + i, BoardW, pitchBandRows[i],
      band, LabelPitch)
    packet.addObject(MapBandObjectBase + i, 0, y, -1000, MapLayerId,
      MapBandSpriteBase + i)
    y += pitchBandRows[i]

proc cogHeadingBrads(cog: Cog): int32 {.inline.} =
  ## A cog faces where it is going; a standing cog keeps its held direction.
  if cog.vx != 0 or cog.vy != 0:
    bradsOfVectorI(cog.vx, cog.vy)
  elif cog.dir >= 1 and cog.dir <= 8:
    DirBrads[cog.dir]
  else:
    0

proc addCogsAndBall(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition],
  selfSeat: int
) =
  const
    rigPx = RigCanvas * BoardScale
    half = rigPx div 2
    chipW = ShirtChipPx * BoardScale
    chipH = (ShirtChipPx * BoardScale * 3) div 4
    ringPx = SeatRingPx * BoardScale
  for i in 0 ..< CogCount:
    let
      cog = sim.cogs[i]
      team = teamOfCog(i)
      step = headingStep(cogHeadingBrads(cog))
      spriteId = rigSpriteId(team, step)
      bxp = worldToBoard(cog.x)
      byp = worldToBoard(cog.y)
    # The seat ring sits UNDER the cog so the rig art stays legible.
    if cog.seat >= 0:
      packet.addSpriteOnce(defs, RingSpriteBase + ord(team), ringPx, ringPx,
        seatRingPixels(team, BoardScale), LabelSeatRing)
      packet.addObject(RingObjectBase + i, bxp - ringPx div 2,
        byp - ringPx div 2, 90 + i, MapLayerId, RingSpriteBase + ord(team))
    else:
      packet.addDeleteObject(RingObjectBase + i)
    packet.addSpriteOnce(defs, spriteId, rigPx, rigPx,
      rigPixels(team, step, BoardScale), LabelCog & " " & cogId(i))
    packet.addObject(CogObjectBase + i, bxp - half, byp - half,
      100 + i, MapLayerId, spriteId)
    packet.addSpriteOnce(defs, chipSpriteId(team, int(cog.shirt)),
      chipW, chipH, shirtChipPixels(team, int(cog.shirt), BoardScale),
      LabelShirtChip)
    packet.addObject(ChipObjectBase + i, bxp - chipW div 2,
      byp - half - chipH, 140 + i, MapLayerId,
      chipSpriteId(team, int(cog.shirt)))
  const ballPx = BallSpritePx * BoardScale
  let
    ballHalf = ballPx div 2
    lift = int((int64(sim.ball.z) * int64(BoardScale)) div
      int64(MapScale) div 2)
  if sim.ball.z > 0:
    packet.addSpriteOnce(defs, BallShadowSpriteId, ballPx, ballPx,
      ballShadowPixels(BoardScale), LabelBallShadow)
    packet.addObject(BallShadowObjectId, worldToBoard(sim.ball.x) - ballHalf,
      worldToBoard(sim.ball.y) - ballHalf, 190, MapLayerId, BallShadowSpriteId)
  else:
    packet.addDeleteObject(BallShadowObjectId)
  packet.addSpriteOnce(defs, BallSpriteId, ballPx, ballPx,
    ballPixels(BoardScale), LabelBall)
  packet.addObject(BallObjectId, worldToBoard(sim.ball.x) - ballHalf,
    worldToBoard(sim.ball.y) - ballHalf - lift, 200, MapLayerId, BallSpriteId)
  if selfSeat >= 0:
    const markerPx = 8 * BoardScale
    let index = cogOfSeat(selfSeat)
    packet.addSpriteOnce(defs, SelfMarkerSpriteId, markerPx, markerPx,
      discPixels(markerPx, rgba(255, 244, 190, 220)), LabelSelfMarker)
    packet.addObject(SelfMarkerObjectId,
      worldToBoard(sim.cogs[index].x) - markerPx div 2,
      worldToBoard(sim.cogs[index].y) - half - chipH - markerPx,
      300, MapLayerId, SelfMarkerSpriteId)

proc addTrail(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## The last 40 tick positions as a tapering ribbon, tinted by the last
  ## toucher's livery.
  let count = min(sim.trail.len, TrailSlots)
  for slot in 0 ..< TrailSlots:
    let index = sim.trail.len - count + slot
    if slot >= count:
      packet.addDeleteObject(TrailObjectBase + slot)
      continue
    let
      point = sim.trail[index]
      stage = slot * TrailStages div max(1, count)
      size = (2 + stage) * BoardScale
      spriteId = trailSpriteId(point.team, stage)
    packet.addSpriteOnce(defs, spriteId, size, size,
      discPixels(size, tintColour(point.team, uint8(24 + stage * 22))),
      LabelBallTrail)
    packet.addObject(TrailObjectBase + slot,
      worldToBoard(point.x) - size div 2, worldToBoard(point.y) - size div 2,
      150, MapLayerId, spriteId)

proc addArcs(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## Pass arcs, shot streaks and save/post bursts, drawn as a chain of small
  ## dots along the play so no sprite is ever board-sized.
  var slot = 0
  for arc in sim.arcs:
    let age = sim.tickCount - int(arc.tick)
    if age < 0 or age >= ArcFxTicks or slot >= ArcSlots:
      continue
    let
      alpha = uint8(max(0, 220 - age * 16))
      size = (if arc.kind == 1: 3 else: 4) * BoardScale
      spriteId = ArcSpriteBase + trailTint(arc.team)
    packet.addSpriteOnce(defs, spriteId, size, size,
      discPixels(size, tintColour(arc.team, alpha)), LabelArc)
    for dot in 0 ..< ArcDots:
      let
        t = dot * 1024 div max(1, ArcDots - 1)
        x = int32(int64(arc.x0) + (int64(arc.x1) - int64(arc.x0)) * t div 1024)
        y = int32(int64(arc.y0) + (int64(arc.y1) - int64(arc.y0)) * t div 1024)
      packet.addObject(ArcObjectBase + slot * ArcDots + dot,
        worldToBoard(x) - size div 2, worldToBoard(y) - size div 2,
        250, MapLayerId, spriteId)
    inc slot
  while slot < ArcSlots:
    for dot in 0 ..< ArcDots:
      packet.addDeleteObject(ArcObjectBase + slot * ArcDots + dot)
    inc slot

proc addGoalFx(
  sim: SimServer,
  packet: var seq[uint8],
  defs: var seq[SpriteDefinition]
) =
  ## A bright flash over the centre circle plus 120 particles in the scoring
  ## livery for 45 frames.
  var active = -1
  var team = 0
  for fx in sim.goalFx:
    let age = sim.tickCount - int(fx.tick)
    if age >= 0 and age < GoalFxTicks:
      active = age
      team = int(fx.team)
  if active < 0:
    packet.addDeleteObject(GoalFlashObjectId)
    for i in 0 ..< ConfettiSlots:
      packet.addDeleteObject(ConfettiObjectBase + i)
    return
  let
    flashAlpha = uint8(max(0, 190 - active * 4))
    tint = if team == 0: RedColor else: BlueColor
  packet.addSpriteOnce(defs, GoalFlashSpriteId, GoalFlashPx, GoalFlashPx,
    discPixels(GoalFlashPx, rgba(255, 255, 255, flashAlpha)), LabelGoalFlash)
  packet.addObject(GoalFlashObjectId,
    worldToBoard(CentreX) - GoalFlashPx div 2,
    worldToBoard(CentreY) - GoalFlashPx div 2, 900, MapLayerId,
    GoalFlashSpriteId)
  const confettiPx = 4 * BoardScale
  packet.addSpriteOnce(defs, ConfettiSpriteBase + team, confettiPx, confettiPx,
    discPixels(confettiPx, rgba(tint.r, tint.g, tint.b, 230)), LabelConfetti)
  for i in 0 ..< ConfettiSlots:
    # Deterministic scatter: derived from the particle index, so a replay
    # re-derives the identical celebration.
    let
      angle = float(i) * 2.399963
      radius = float(50 + (i * 37) mod 300) * float(active) / float(GoalFxTicks)
      cx = worldToBoard(CentreX) + int(cos(angle) * radius * float(BoardScale))
      cy = worldToBoard(CentreY) + int(sin(angle) * radius * float(BoardScale)) +
        active * 2
    packet.addObject(ConfettiObjectBase + i, cx, cy, 950, MapLayerId,
      ConfettiSpriteBase + team)

# --------------------------------------------------------------------------
# The two builders
# --------------------------------------------------------------------------

proc buildBoard(
  sim: SimServer,
  defs: var seq[SpriteDefinition],
  initialized: var bool,
  selfSeat: int
): seq[uint8] =
  if not initialized:
    result.addBoardChrome(defs)
    initialized = true
  sim.addTrail(result, defs)
  sim.addArcs(result, defs)
  sim.addCogsAndBall(result, defs, selfSeat)
  sim.addGoalFx(result, defs)

proc buildSpriteProtocolUpdates*(
  sim: var SimServer,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  tick: int,
  playing: bool,
  speed: int,
  maxTick: int,
  looping: bool,
  transportEnabled: bool,
  mismatchTick: int
): seq[uint8] =
  ## The SPECTATOR / replay board. Perfect information: no fog, no vision cone,
  ## no first-person inset — football is a perfect-information sport.
  nextState = state
  result = buildBoard(sim, nextState.spriteDefs, nextState.initialized, -1)
  discard tick
  discard playing
  discard speed
  discard maxTick
  discard looping
  discard transportEnabled
  discard mismatchTick

proc buildSpriteProtocolPlayerUpdates*(
  sim: var SimServer,
  playerIndex: int,
  state: PlayerViewerState,
  nextState: var PlayerViewerState,
  spritesOff = false
): seq[uint8] =
  ## One seat's stream. It sees the whole pitch and all 22 cogs — plus a self
  ## marker on its own shirt and an invisible `own seat <alias>` marker naming
  ## it. It never sees a real player name, and that is STRUCTURAL rather than a
  ## switch: every board label is built from `cogId()` in `labels.nim`, so
  ## there is no code path that could put `player.address` on the board and
  ## nothing for `config.showPlayerLabels` to gate. The flag stays because the
  ## manifest's config_schema declares it and it defaults false;
  ## tests/test_identity_privacy.nim asserts the guarantee holds with it forced
  ## TRUE, which is the only way to show the mechanism is the vocabulary and
  ## not the flag.
  nextState = state
  if nextState.isNil:
    nextState = initPlayerViewerState()
  let seat =
    if playerIndex >= 0 and playerIndex < sim.players.len:
      int(sim.players[playerIndex].seat)
    else:
      -1
  result = buildBoard(sim, nextState.spriteDefs, nextState.initialized, seat)
  if seat >= 0:
    result.addSpriteOnce(nextState.spriteDefs, OwnSeatSpriteId, 1, 1,
      @[0'u8, 0, 0, 0], LabelOwnSeat & " " & cogId(cogOfSeat(seat)))
    result.addObject(OwnSeatObjectId, 0, 0, 999, MapLayerId, OwnSeatSpriteId)
  discard spritesOff
