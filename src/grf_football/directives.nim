## Directives: the order a seat plays for one 240-tick decision turn, its
## tolerant parser/repairer, and the view-coordinate transform every policy
## sees the world through.
##
## Two hard rules live here and are pinned by tests/test_directives.nim:
##
## 1. **Every recorded string is truncated on RUNE boundaries, never bytes.**
##    A byte-truncated multi-byte character is exactly the bug that makes
##    replay bytes render in a browser but fail a strict parser.
## 2. **Parsing is tolerant and never fails hard.** Markdown fences, prose
##    prefixes, an id-keyed `cogs` object, numeric strings, unknown enums,
##    out-of-pitch targets, extra entries, zero entries — all repair. Only when
##    no object with a usable entry can be recovered do the retry and then the
##    scripted fallback fire.

import
  std/[json, math, strutils, unicode],
  sim

# --------------------------------------------------------------------------
# View coordinates: metres from the centre spot, x toward blue's goal. The
# ONLY coordinates a policy ever sees or sends.
# --------------------------------------------------------------------------

const
  ViewHalfW* = 42.0
  ViewHalfH* = 27.0
  GoalHalfWidth* = 4.0

proc viewX*(x: int32): float {.inline.} =
  float(int(x) - int(CentreX)) / 1_000_000.0

proc viewY*(y: int32): float {.inline.} =
  float(int(y) - int(CentreY)) / 1_000_000.0

proc worldXOfView*(v: float): int32 {.inline.} =
  int32(int(CentreX) + int(round(clamp(v, -ViewHalfW, ViewHalfW) * 1_000_000.0)))

proc worldYOfView*(v: float): int32 {.inline.} =
  int32(int(CentreY) + int(round(clamp(v, -ViewHalfH, ViewHalfH) * 1_000_000.0)))

proc round1*(value: float): float {.inline.} =
  ## One decimal, the precision every number in the seat view carries.
  round(value * 10.0) / 10.0

proc metresPerSecond*(umPerTick: int32): float {.inline.} =
  float(umPerTick) * float(TargetFps) / 1_000_000.0

# --------------------------------------------------------------------------
# Rune-boundary truncation
# --------------------------------------------------------------------------

proc clipRunes*(text: string, maxRunes: int): string =
  ## Truncates on a RUNE boundary. Slicing a `string` by byte index on any path
  ## to the replay is forbidden.
  result = text.strip()
  var clean = newStringOfCap(result.len)
  for rune in result.runes:
    # Control characters would corrupt a replay chat record and a JSON line.
    if int32(rune) >= 32 or int32(rune) == 9:
      clean.add($rune)
  result = clean
  if maxRunes <= 0:
    return ""
  if result.runeLen <= maxRunes:
    return
  result = result.runeSubStr(0, maxRunes - 1) & "\u2026"

# --------------------------------------------------------------------------
# Cog ids
# --------------------------------------------------------------------------

proc cogIndexOfId*(id: string): int =
  ## `RED-1`..`RED-11` / `BLUE-1`..`BLUE-11`, case-insensitive,
  ## separator-tolerant. -1 when the token names no shirt.
  let text = clipRunes(id, MaxCogIdRunes).toUpperAscii()
  var digits = ""
  var prefix = ""
  for ch in text:
    if ch in {'A' .. 'Z'}:
      if prefix.len < 4: prefix.add(ch)
    elif ch in {'0' .. '9'}:
      digits.add(ch)
  if digits.len == 0:
    return -1
  var shirt: int
  try:
    shirt = parseInt(digits)
  except ValueError:
    return -1
  if shirt < 1 or shirt > CogsPerTeam:
    return -1
  case prefix
  of "RED": cogOfShirt(Red, shirt)
  of "BLUE": cogOfShirt(Blue, shirt)
  else: -1

# --------------------------------------------------------------------------
# Enum repair
# --------------------------------------------------------------------------

proc roleOfText*(text: string, fallback: Role): Role =
  case text.strip().toLowerAscii()
  of "striker": roleStriker
  of "winger": roleWinger
  of "playmaker": rolePlaymaker
  of "anchor": roleAnchor
  else: fallback        ## the documented repair: the shirt's table role.

proc intentOfText*(text: string): Intent =
  case text.strip().toLowerAscii()
  of "press": inPress
  of "hold_shape": inHoldShape
  of "make_run": inMakeRun
  of "drop_deep": inDropDeep
  of "carry": inCarry
  of "switch_play": inSwitchPlay
  of "shadow": inShadow
  else: inSupport       ## the documented repair for an unknown intent.

proc onBallOfText*(text: string): OnBall =
  case text.strip().toLowerAscii()
  of "shoot": obShoot
  of "pass_long": obPassLong
  of "pass_high": obPassHigh
  of "dribble": obDribble
  of "hold": obHold
  else: obPassShort     ## the documented repair for an unknown on_ball.

proc sprintOfText*(text: string): SprintMode =
  case text.strip().toLowerAscii()
  of "always": spAlways
  of "never": spNever
  else: spAuto

proc tackleOfText*(text: string): TackleMode =
  if text.strip().toLowerAscii() == "never": tkNever else: tkAuto

# --------------------------------------------------------------------------
# Directive construction and serialization
# --------------------------------------------------------------------------

proc emptyDirective*(seat: int): Directive =
  result.source = dsScripted
  result.half = 1
  result.cog = CogOrder(
    role: SeatRole[clamp(seat, 0, SeatCount - 1)],
    intent: inSupport,
    targetX: CentreX, targetY: CentreY,
    onBall: obPassShort, passTo: -1,
    sprint: spAuto, tackle: tkAuto, say: "")

proc directiveJson*(seat: int, directive: Directive): JsonNode =
  ## The `directive` replay chat record. Capped at MaxDirectiveRecordRunes by
  ## the caller (`capRecord` below).
  let
    index = cogOfSeat(seat)
    order = directive.cog
  var cogs = newJArray()
  cogs.add(%*{
    "id": cogId(index),
    "role": roleText(order.role),
    "intent": intentText(order.intent),
    "target": [round1(viewX(order.targetX)), round1(viewY(order.targetY))],
    "on_ball": onBallText(order.onBall),
    "pass_to": (if order.passTo >= 0: %cogId(int(order.passTo))
                else: newJNull()),
    "sprint": sprintText(order.sprint),
    "tackle": tackleText(order.tackle),
    "say": order.say
  })
  %*{
    "k": "directive",
    "turn": directive.turn,
    "half": directive.half,
    "seat": seat,
    "id": cogId(index),
    "team": teamText(teamOfSeat(seat)),
    "source": sourceText(directive.source),
    "latency_ms": directive.latencyMs,
    "note": directive.note,
    "cogs": cogs
  }

proc clipJsonStrings(node: JsonNode, budget: int): JsonNode =
  ## A copy of `node` with every STRING VALUE clipped to `budget` runes. Keys
  ## are untouched, so the shape a reader matches on survives.
  case node.kind
  of JString:
    result = %clipRunes(node.getStr(), budget)
  of JArray:
    result = newJArray()
    for item in node:
      result.add(clipJsonStrings(item, budget))
  of JObject:
    result = newJObject()
    for key, value in node:
      result[key] = clipJsonStrings(value, budget)
  else:
    result = node

proc capRecord*(text: string): string =
  ## Every replay chat record is capped at MaxDirectiveRecordRunes runes, on a
  ## rune boundary.
  ##
  ## The cap is on the SERIALIZED record, and JSON escaping is what makes that
  ## non-obvious: a `"` or a `\` inside a note or a say costs two runes on the
  ## wire. Blindly clipping the serialized text would cut the object mid-key:
  ## still valid UTF-8 on a rune boundary, but no longer JSON — and
  ## `broadcast.applyRecord` would silently drop the feed line while
  ## `tools/replay_summary.py` skipped the record, so phase 60 would
  ## under-count exactly the LLM directives it is there to verify.
  ##
  ## So an over-long record is shrunk STRUCTURALLY: parse it, clip its string
  ## values to a halving budget until the serialization fits, and only fall
  ## back to the blind rune clip when the text is not a JSON object at all.
  if text.runeLen <= MaxDirectiveRecordRunes:
    return clipRunes(text, MaxDirectiveRecordRunes)
  var node: JsonNode
  try:
    node = parseJson(text)
  except CatchableError:
    return clipRunes(text, MaxDirectiveRecordRunes)
  if node.kind != JObject:
    return clipRunes(text, MaxDirectiveRecordRunes)
  var budget = MaxNoteRunes
  while budget > 0:
    budget = budget div 2
    let shrunk = $clipJsonStrings(node, budget)
    if shrunk.runeLen <= MaxDirectiveRecordRunes:
      return shrunk
  clipRunes(text, MaxDirectiveRecordRunes)

# --------------------------------------------------------------------------
# The tolerant parser
# --------------------------------------------------------------------------

proc numberOf(node: JsonNode, ok: var bool): float =
  ## Accepts a JSON number OR a numeric string; anything else, or a non-finite
  ## value, reports `ok = false`.
  ok = false
  if node.isNil:
    return 0.0
  case node.kind
  of JInt:
    ok = true
    return float(node.getInt())
  of JFloat:
    let value = node.getFloat()
    if value != value or value == Inf or value == NegInf:
      return 0.0
    ok = true
    return value
  of JString:
    try:
      let value = parseFloat(node.getStr().strip())
      if value != value or value == Inf or value == NegInf:
        return 0.0
      ok = true
      return value
    except ValueError:
      return 0.0
  else:
    return 0.0

proc entriesOf(node: JsonNode): seq[tuple[id: string, body: JsonNode]] =
  ## `cogs` may arrive as an array of objects, as a single bare object, or as
  ## an object keyed by shirt id. All three reduce to (id, body) pairs; the id
  ## inside the body wins.
  if node.isNil:
    return
  case node.kind
  of JArray:
    for entry in node:
      if entry.kind == JObject:
        result.add((entry{"id"}.getStr(), entry))
  of JObject:
    if node.hasKey("intent") or node.hasKey("role") or node.hasKey("target"):
      # A bare order object, not a map of them.
      return @[(node{"id"}.getStr(), node)]
    for key, entry in node:
      if entry.kind == JObject:
        let inner = entry{"id"}.getStr()
        let useId = if inner.len > 0: inner else: key
        result.add((useId, entry))
  else:
    discard

proc parseDirective*(
  sim: SimServer,
  seat: int,
  payload: JsonNode,
  previous: Directive,
  hasPrevious: bool,
  fallback: Directive,
  turn: int
): tuple[directive: Directive, usable: bool] =
  ## Repairs one reply into a legal directive. `usable` is false when no cog
  ## entry could be recovered at all — the only case that triggers the retry.
  let index = cogOfSeat(seat)
  var directive = fallback
  directive.turn = int32(turn)
  directive.half = sim.half
  directive.source = dsLlm
  directive.note = clipRunes(payload{"note"}.getStr(), MaxNoteRunes)

  var entries = entriesOf(payload{"cogs"})
  if entries.len == 0:
    entries = entriesOf(payload{"cog"})
  var usable = false
  for entry in entries:
    # A seat commands exactly one shirt, so the FIRST usable entry wins and
    # every extra entry is dropped. An id naming another shirt is assigned to
    # this seat's shirt by position, which is the documented repair.
    if usable:
      break
    let body = entry.body
    var order = CogOrder()
    order.role = roleOfText(body{"role"}.getStr(), SeatRole[seat])
    order.intent = intentOfText(body{"intent"}.getStr())
    order.onBall = onBallOfText(body{"on_ball"}.getStr())
    order.sprint = sprintOfText(body{"sprint"}.getStr("auto"))
    order.tackle = tackleOfText(body{"tackle"}.getStr("auto"))
    order.say = clipRunes(body{"say"}.getStr(), MaxSayRunes)
    # target: two finite numbers, clamped into the pitch; anything else falls
    # back to the cog's CURRENT position.
    var okX = false
    var okY = false
    var vx = 0.0
    var vy = 0.0
    let target = body{"target"}
    if not target.isNil and target.kind == JArray and target.len >= 2:
      vx = numberOf(target[0], okX)
      vy = numberOf(target[1], okY)
    elif not target.isNil and target.kind == JObject:
      vx = numberOf(target{"x"}, okX)
      vy = numberOf(target{"y"}, okY)
    if okX and okY:
      order.targetX = worldXOfView(vx)
      order.targetY = worldYOfView(vy)
    else:
      order.targetX = sim.cogs[index].x
      order.targetY = sim.cogs[index].y
    # pass_to: a TEAMMATE shirt that is not this cog; anything else is null.
    order.passTo = -1
    let passNode = body{"pass_to"}
    if not passNode.isNil and passNode.kind == JString:
      let mate = cogIndexOfId(passNode.getStr())
      if mate >= 0 and mate != index and
          teamOfCog(mate) == teamOfSeat(seat):
        order.passTo = int32(mate)
    directive.cog = order
    usable = true

  if not usable:
    # A missing entry keeps last turn's order, else the scripted fallback's.
    directive.cog = if hasPrevious: previous.cog else: fallback.cog
  (directive, usable)
