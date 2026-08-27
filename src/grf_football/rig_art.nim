## Broadcast-side art: the wheeled-rig compositor, the shirt-number chip, the
## seat ring, the ball and the small round/ring bakes.
##
## Everything here is BROADCAST-ONLY: no sim state, nothing in gameHash, no
## GameVersion bump for changes. The cogs are the SHIPPED `data/rig_real/red`
## and `data/rig_real/blue` wheeled rigs — head, arms, three legs, three wheels
## — composed exactly as coworld-ctf composes them: every segment is rotated
## about its own anchor in the same 192 px master frame and the hub lands at
## the canvas centre, so at rest the segments recompose to the south master.
## Floats are legal here; rendering never enters `gameHash`.

import
  std/[math, os, tables],
  pixie,
  sim_types

type
  RigSeg* = enum
    rsHead, rsArmL, rsArmR, rsLegFL, rsLegFR, rsLegRear,
    rsWheelL, rsWheelR, rsWheelRear

const
  RigSteps* = 16              ## baked heading steps (16 brads apart).
  RigCanvas* = 44             ## px square cog sprite canvas at 1x.
  CogBodyPx* = 11             ## the drawn body diameter in MAP pixels.
                              ## The collision circle is 1.0 m = 13.3 map px;
                              ## the cog is drawn LARGER THAN LIFE relative to
                              ## its 6.7 map-px radius so that at 360 px of
                              ## board (0.30 screen px per map px) it is still
                              ## a ~6.6 px disc in its team colour.
  BallSpritePx* = 8           ## 0.44 m ball + rim, in map pixels.
  ShirtChipPx* = 12           ## the shirt-number chip, in map pixels.
  SeatRingPx* = 18            ## the bright ring on a policy-driven shirt.

  # Anchors in 192 px master-frame space (coworld-ctf's rig anchors.json).
  RigHub: tuple[x, y: float] = (96.0, 88.0)
  RigAnchor: array[RigSeg, tuple[x, y: float]] = [
    (96.0, 88.0),     # rsHead      (== hub; the head rotates about the hub)
    (70.0, 84.0),     # rsArmL      left shoulder attach
    (120.0, 84.0),    # rsArmR      right shoulder attach
    (72.0, 100.0),    # rsLegFL     left front hip
    (120.0, 100.0),   # rsLegFR     right front hip
    (96.0, 80.0),     # rsLegRear   rear hip
    (73.5, 134.0),    # rsWheelL    left front tire centroid
    (117.3, 132.7),   # rsWheelR    right front tire centroid
    (94.7, 48.3)]     # rsWheelRear rear tire centroid
  RigRestTuckDeg = 2.0
  RigBodySpan = 99.0          ## the solid body's span in the master frame.

var
  rigLoaded: array[Team, bool]
  rigSegImg: array[Team, array[RigSeg, Image]]
  rigCache = initTable[int, seq[uint8]]()
  ballCache = initTable[int, seq[uint8]]()
  shadowCache = initTable[int, seq[uint8]]()
  chipCache = initTable[string, seq[uint8]]()
  ringCache = initTable[int, seq[uint8]]()
  discCache = initTable[(int, uint8, uint8, uint8, uint8), seq[uint8]]()
    ## Keyed by a TUPLE, not a packed int: `int` is 32 bits under
    ## --cpu:wasm32 and a size-major packing overflows it.
  typefaceCache: Typeface

proc gameDir*(): string =
  ## Assets resolve against the process working directory, exactly as ctf does
  ## (the Dockerfile copies `data/` next to the binary and the emscripten build
  ## preloads it as `data`).
  getCurrentDir()

proc boardTypeface(): Typeface =
  if typefaceCache.isNil:
    typefaceCache = readTypeface(gameDir() / "data" / "font.ttf")
  typefaceCache

proc teamColour*(team: Team): ColorRGBA {.inline.} =
  if team == Red: RedColor else: BlueColor

proc rigSegPath(seg: RigSeg): string =
  case seg
  of rsHead: "head"
  of rsArmL: "arm_l"
  of rsArmR: "arm_r"
  of rsLegFL: "leg_fl"
  of rsLegFR: "leg_fr"
  of rsLegRear: "leg_rear"
  of rsWheelL: "wheel_l"
  of rsWheelR: "wheel_r"
  of rsWheelRear: "wheel_rear"

proc rigSegIsLeg(seg: RigSeg): bool =
  seg in {rsLegFL, rsLegFR, rsLegRear}

proc ensureRigLoaded(team: Team) =
  if rigLoaded[team]:
    return
  let dir = gameDir() / "data" / "rig_real" / teamText(team)
  for seg in RigSeg:
    rigSegImg[team][seg] = readImage(dir / rigSegPath(seg) & ".png")
  rigLoaded[team] = true

proc canvasToPixels(canvas: Image): seq[uint8] =
  ## Straight-alpha RGBA for the Sprite v1 protocol (pixie stores
  ## premultiplied).
  result = newSeq[uint8](canvas.width * canvas.height * 4)
  for i in 0 ..< canvas.width * canvas.height:
    let c = canvas.data[i].rgba()
    result[i * 4] = c.r
    result[i * 4 + 1] = c.g
    result[i * 4 + 2] = c.b
    result[i * 4 + 3] = c.a

proc headingStep*(brads: int32): int =
  ## Nearest of the RigSteps baked headings.
  ((int(brads) + AimBradsTurn div (RigSteps * 2)) * RigSteps div
    AimBradsTurn) mod RigSteps

proc rigPixels*(team: Team, step: int, renderScale = 1): seq[uint8] =
  ## The whole cog at one heading step, hub-centred in a RigCanvas sprite:
  ## drop shadow, then the nine rig segments rotated about their own anchors.
  ## Cached for the life of the process: 2 liveries x 16 steps x scale.
  let
    b = ((step mod RigSteps) + RigSteps) mod RigSteps
    key = (ord(team) * RigSteps + b) * 8 + renderScale
  if rigCache.hasKey(key):
    return rigCache[key]
  ensureRigLoaded(team)
  let
    k = float32(renderScale)
    outCanvas = RigCanvas * renderScale
    centre = float32(outCanvas) / 2
    s = float32(CogBodyPx) * k / float32(RigBodySpan)
    baseAngle = float(b) * 2.0 * PI / float(RigSteps)
    # rot 0 = east; the master faces SOUTH, so the -90 degree turn makes the
    # face lead the base direction. Angle increases CCW; screen y is down.
    baseDeg = -baseAngle - PI / 2.0
  var canvas = newImage(outCanvas, outCanvas)
  # Drop shadow, under everything.
  let shadow = newImage(outCanvas, outCanvas)
  let shadowCtx = newContext(shadow)
  shadowCtx.fillStyle = rgba(0, 0, 0, 80)
  shadowCtx.fillEllipse(vec2(centre, centre + 2.0'f32 * k),
    float32(CogBodyPx) * k * 0.52, float32(CogBodyPx) * k * 0.26)
  shadow.blur(1.6 * k)
  canvas.draw(shadow)
  let
    toCentre = translate(vec2(centre, centre))
    baseRot = rotate(float32(baseDeg))
    scl = scale(vec2(float32(s), float32(s)))
    hubToOrigin = translate(vec2(float32(-RigHub.x), float32(-RigHub.y)))
  for seg in RigSeg:
    var artDeg = 0.0
    if rigSegIsLeg(seg):
      artDeg =
        (case seg
         of rsLegFL: -RigRestTuckDeg
         of rsLegFR: RigRestTuckDeg
         else: 0.0) * PI / 180.0
    let
      anchor = RigAnchor[seg]
      artMat =
        translate(vec2(float32(anchor.x), float32(anchor.y))) *
        rotate(float32(artDeg)) *
        translate(vec2(float32(-anchor.x), float32(-anchor.y)))
      mat = toCentre * baseRot * scl * hubToOrigin * artMat
    canvas.draw(rigSegImg[team][seg], mat)
  result = canvasToPixels(canvas)
  rigCache[key] = result

proc ballPixels*(renderScale = 1): seq[uint8] =
  ## A baked shaded sphere with a rolling seam — no solid-colour placeholder.
  if ballCache.hasKey(renderScale):
    return ballCache[renderScale]
  let
    size = BallSpritePx * renderScale
    r = float32(size) / 2.0
  var canvas = newImage(size, size)
  let ctx = newContext(canvas)
  ctx.fillStyle = BallColor
  ctx.fillEllipse(vec2(r, r), r * 0.92, r * 0.92)
  ctx.fillStyle = rgba(198, 200, 192, 255)
  ctx.fillEllipse(vec2(r, r + r * 0.26), r * 0.84, r * 0.56)
  ctx.fillStyle = rgba(34, 36, 34, 235)
  ctx.fillEllipse(vec2(r * 0.72, r * 0.78), r * 0.20, r * 0.16)
  ctx.fillEllipse(vec2(r * 1.32, r * 1.18), r * 0.16, r * 0.13)
  ctx.fillStyle = rgba(255, 255, 255, 200)
  ctx.fillEllipse(vec2(r * 0.74, r * 0.60), r * 0.26, r * 0.18)
  result = canvasToPixels(canvas)
  ballCache[renderScale] = result

proc ballShadowPixels*(renderScale = 1): seq[uint8] =
  ## The separate drop shadow used while the ball is airborne.
  if shadowCache.hasKey(renderScale):
    return shadowCache[renderScale]
  let
    size = BallSpritePx * renderScale
    r = float32(size) / 2.0
  var canvas = newImage(size, size)
  let ctx = newContext(canvas)
  ctx.fillStyle = rgba(10, 16, 12, 120)
  ctx.fillEllipse(vec2(r, r), r * 0.80, r * 0.50)
  canvas.blur(max(0.8'f32, r * 0.25))
  result = canvasToPixels(canvas)
  shadowCache[renderScale] = result

proc shirtChipPixels*(team: Team, shirt: int, renderScale = 1): seq[uint8] =
  ## The baked shirt-number chip: a dark rounded plate with the number set in
  ## the board face, edged in the team's livery. Two liveries x eleven shirts.
  let key = teamText(team) & ":" & $shirt & ":" & $renderScale
  if chipCache.hasKey(key):
    return chipCache[key]
  let
    w = ShirtChipPx * renderScale
    h = (ShirtChipPx * renderScale * 3) div 4
    edge = teamColour(team)
  var canvas = newImage(w, h)
  var plate = newPath()
  plate.roundedRect(rect(0.5, 0.5, float32(w) - 1.0, float32(h) - 1.0),
    2.0, 2.0, 2.0, 2.0)
  canvas.fillPath(plate, rgba(14, 12, 10, 220))
  canvas.strokePath(plate,
    color(float32(edge.r) / 255, float32(edge.g) / 255,
      float32(edge.b) / 255, 1.0),
    strokeWidth = float32(renderScale))
  let font = newFont(boardTypeface())
  font.size = float32(h) * 0.92
  font.paint = newPaint(SolidPaint)
  font.paint.color = color(0.96, 0.93, 0.88, 1.0)
  let
    text = $shirt
    bounds = font.layoutBounds(text)
    tx = (float32(w) - bounds.x) / 2.0
    ty = (float32(h) - bounds.y) / 2.0
  canvas.fillText(font, text, translate(vec2(max(0.0'f32, tx),
    max(0.0'f32, ty))))
  result = canvasToPixels(canvas)
  chipCache[key] = result

proc seatRingPixels*(team: Team, renderScale = 1): seq[uint8] =
  ## The bright ring that marks one of the eight POLICY-DRIVEN shirts.
  let key = ord(team) * 8 + renderScale
  if ringCache.hasKey(key):
    return ringCache[key]
  let
    size = SeatRingPx * renderScale
    r = float32(size) / 2.0
    edge = teamColour(team)
  var canvas = newImage(size, size)
  let ctx = newContext(canvas)
  ctx.strokeStyle = rgba(250, 244, 214, 235)
  ctx.lineWidth = max(1.4'f32, float32(renderScale) * 1.2)
  ctx.strokeEllipse(vec2(r, r), r - ctx.lineWidth, (r - ctx.lineWidth) * 0.62)
  ctx.strokeStyle = rgba(edge.r, edge.g, edge.b, 190)
  ctx.lineWidth = max(0.8'f32, float32(renderScale) * 0.6)
  ctx.strokeEllipse(vec2(r, r), r * 0.72, r * 0.44)
  result = canvasToPixels(canvas)
  ringCache[key] = result

proc discPixels*(size: int, colour: ColorRGBA, feather = true): seq[uint8] =
  ## A soft round dot: the ball trail, the confetti and the goal flash all draw
  ## from this one bake, keyed by (size, colour).
  let key = (size, colour.r, colour.g, colour.b, colour.a)
  if discCache.hasKey(key):
    return discCache[key]
  var canvas = newImage(max(1, size), max(1, size))
  let
    ctx = newContext(canvas)
    r = float32(size) / 2.0
  ctx.fillStyle = colour
  ctx.fillEllipse(vec2(r, r), r * (if feather: 0.86 else: 1.0),
    r * (if feather: 0.86 else: 1.0))
  if feather:
    canvas.blur(max(0.6'f32, r * 0.20))
  result = canvasToPixels(canvas)
  discCache[key] = result

proc segmentPixels*(
  width, height: int,
  x0, y0, x1, y1: float32,
  colour: ColorRGBA,
  thickness: float32
): seq[uint8] =
  ## A straight line inside a sprite of the given size: pass arcs and shot
  ## streaks. Not cached — every arc has its own geometry.
  var canvas = newImage(max(1, width), max(1, height))
  let ctx = newContext(canvas)
  ctx.strokeStyle = colour
  ctx.lineWidth = thickness
  ctx.strokeSegment(segment(vec2(x0, y0), vec2(x1, y1)))
  canvasToPixels(canvas)

proc ringPixels*(size: int, colour: ColorRGBA, thickness: float32): seq[uint8] =
  ## A burst ring for a save or a post. Keyed by the caller's stage, so not
  ## cached here.
  var canvas = newImage(max(1, size), max(1, size))
  let
    ctx = newContext(canvas)
    r = float32(size) / 2.0
  ctx.strokeStyle = colour
  ctx.lineWidth = thickness
  ctx.strokeEllipse(vec2(r, r), r - thickness, r - thickness)
  canvasToPixels(canvas)
