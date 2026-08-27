## Tolerant parsing and repair, and the RUNE-BOUNDARY truncation discipline.

import std/[json, strutils, unicode]
import lib/helpers

proc parse(sim: SimServer, seat: int, text: string):
    tuple[directive: Directive, usable: bool] =
  let payload = extractJsonObject(text)
  sim.parseDirective(seat, payload, emptyDirective(seat), false,
    sim.zonalDirective(seat, 0), 0)

proc fencedAndProseWrapped() =
  var sim = playing(testConfig())
  let fenced = "```json\n{\"note\":\"ok\",\"cogs\":[{\"id\":\"RED-9\"," &
    "\"intent\":\"press\",\"target\":[3,4]}]}\n```"
  let a = parse(sim, 2, fenced)
  doAssert a.usable, "a fenced reply parses"
  doAssert a.directive.cog.intent == inPress
  let prose = "Sure! Here is my order:\n{\"note\":\"ok\"," &
    "\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"shadow\",\"target\":[1,1]}]}"
  let b = parse(sim, 2, prose)
  doAssert b.usable, "a prose-prefixed reply parses"
  doAssert b.directive.cog.intent == inShadow
  report "markdown fences and a prose prefix both parse"

proc bareObjectAndKeyedObject() =
  var sim = playing(testConfig())
  let bare = "{\"note\":\"n\",\"cogs\":{\"id\":\"RED-9\",\"intent\":\"carry\"," &
    "\"target\":[0,0]}}"
  doAssert parse(sim, 2, bare).usable, "a bare cogs object parses"
  let keyed = "{\"note\":\"n\",\"cogs\":{\"RED-9\":{\"intent\":\"support\"," &
    "\"target\":[0,0]}}}"
  let k = parse(sim, 2, keyed)
  doAssert k.usable, "an id-keyed cogs object parses"
  doAssert k.directive.cog.intent == inSupport
  report "cogs as a bare object and as an id-keyed map both parse"

proc numericStringsAndClamps() =
  var sim = playing(testConfig())
  let text = "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"make_run\"," &
    "\"target\":[\"12.5\",\"-3\"]}]}"
  let a = parse(sim, 2, text)
  doAssert a.usable
  doAssert a.directive.cog.targetX == worldXOfView(12.5)
  doAssert a.directive.cog.targetY == worldYOfView(-3.0)
  let far = "{\"cogs\":[{\"id\":\"RED-9\",\"target\":[9999,-9999]}]}"
  let b = parse(sim, 2, far)
  doAssert b.directive.cog.targetX == worldXOfView(42.0),
    "an out-of-range target is clamped to the pitch"
  doAssert b.directive.cog.targetY == worldYOfView(-27.0)
  report "numeric strings parse and out-of-range targets clamp"

proc unknownEnumsRepair() =
  var sim = playing(testConfig())
  let text = "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"teleport\"," &
    "\"role\":\"goalkeeper\",\"on_ball\":\"bicycle_kick\"," &
    "\"sprint\":\"maybe\",\"tackle\":\"perhaps\",\"target\":[0,0]}]}"
  let d = parse(sim, 2, text).directive
  doAssert d.cog.intent == inSupport, "an unknown intent repairs to support"
  doAssert d.cog.role == SeatRole[2], "an unknown role repairs to the shirt's"
  doAssert d.cog.onBall == obPassShort, "an unknown on_ball repairs"
  doAssert d.cog.sprint == spAuto
  doAssert d.cog.tackle == tkAuto
  report "every unknown enum repairs to the documented default"

proc passToRepairs() =
  var sim = playing(testConfig())
  let opponent = "{\"cogs\":[{\"id\":\"RED-9\",\"pass_to\":\"BLUE-4\"," &
    "\"target\":[0,0]}]}"
  doAssert parse(sim, 2, opponent).directive.cog.passTo == -1,
    "pass_to naming an opponent repairs to null"
  let self = "{\"cogs\":[{\"id\":\"RED-9\",\"pass_to\":\"RED-9\"," &
    "\"target\":[0,0]}]}"
  doAssert parse(sim, 2, self).directive.cog.passTo == -1,
    "pass_to naming yourself repairs to null"
  let mate = "{\"cogs\":[{\"id\":\"RED-9\",\"pass_to\":\"red-10\"," &
    "\"target\":[0,0]}]}"
  doAssert parse(sim, 2, mate).directive.cog.passTo ==
    int32(cogOfShirt(Red, 10)), "pass_to is case-insensitive"
  report "pass_to repairs to null unless it names a teammate"

proc extraAndMissingEntries() =
  var sim = playing(testConfig())
  let extra = "{\"cogs\":[{\"id\":\"RED-9\",\"intent\":\"press\"," &
    "\"target\":[0,0]},{\"id\":\"RED-10\",\"intent\":\"carry\"," &
    "\"target\":[0,0]}]}"
  let a = parse(sim, 2, extra)
  doAssert a.usable
  doAssert a.directive.cog.intent == inPress, "extra entries are dropped"
  let empty = "{\"note\":\"nothing\",\"cogs\":[]}"
  let payload = extractJsonObject(empty)
  let previous = sim.zonalDirective(2, 7)
  let b = sim.parseDirective(2, payload, previous, true,
    sim.zonalDirective(2, 8), 8)
  doAssert not b.usable, "no usable entry is the only retry trigger"
  doAssert b.directive.cog.intent == previous.cog.intent,
    "a missing entry keeps last turn's order"
  report "extra entries drop and a missing entry keeps last turn's order"

proc unmatchedIdIsAssignedByPosition() =
  var sim = playing(testConfig())
  let text = "{\"cogs\":[{\"id\":\"BLUE-11\",\"intent\":\"drop_deep\"," &
    "\"target\":[0,0]}]}"
  let d = parse(sim, 2, text)
  doAssert d.usable, "an unmatched id is assigned to the seat's shirt"
  doAssert d.directive.cog.intent == inDropDeep
  let record = directiveJson(2, d.directive)
  doAssert record["cogs"][0]["id"].getStr == cogId(cogOfSeat(2)),
    "the recorded id is always the seat's own shirt"
  report "an unmatched id is assigned to the seat's shirt by position"

proc runeTruncationOnTheBoundary() =
  ## A note whose 160th rune is a 4-byte emoji truncates on the RUNE boundary
  ## and the result is still valid UTF-8. A byte-truncated multi-byte character
  ## is exactly the bug that makes replay bytes fail a strict parser.
  var note = ""
  for _ in 0 ..< (MaxNoteRunes - 1):
    note.add("a")
  note.add("\xF0\x9F\x8F\x86")     ## U+1F3C6 TROPHY, four bytes
  note.add("tail that must go")
  let clipped = clipRunes(note, MaxNoteRunes)
  doAssert clipped.runeLen <= MaxNoteRunes,
    "the clip respects the rune cap, got " & $clipped.runeLen
  doAssert isValidUtf8(clipped), "the clip is valid UTF-8"
  doAssert clipped.validateUtf8() == -1, "std/unicode agrees it is valid UTF-8"
  var emojiOnly = ""
  for _ in 0 ..< 400:
    emojiOnly.add("\xF0\x9F\x8F\x86")
  let clippedEmoji = clipRunes(emojiOnly, MaxSayRunes)
  doAssert clippedEmoji.runeLen <= MaxSayRunes
  doAssert isValidUtf8(clippedEmoji)
  report "truncation lands on rune boundaries, emoji included"

proc recordsStayUnderTheCap() =
  var sim = playing(testConfig())
  var d = sim.zonalDirective(2, 5)
  d.note = clipRunes(repeat("\"quoted\\ ", 60), MaxNoteRunes)
  d.cog.say = clipRunes(repeat("\"say\\ ", 40), MaxSayRunes)
  let record = capRecord($directiveJson(2, d))
  doAssert record.runeLen <= MaxDirectiveRecordRunes,
    "a directive record is capped at 900 runes, got " & $record.runeLen
  doAssert isValidUtf8(record)
  let node = parseJson(record)
  doAssert node.kind == JObject and node{"k"}.getStr == "directive",
    "an over-long record is shrunk STRUCTURALLY and stays parseable"
  report "a directive record is capped at 900 runes and stays parseable JSON"

when isMainModule:
  echo "test_directives"
  fencedAndProseWrapped()
  bareObjectAndKeyedObject()
  numericStringsAndClamps()
  unknownEnumsRepair()
  passToRepairs()
  extraAndMissingEntries()
  unmatchedIdIsAssignedByPosition()
  runeTruncationOnTheBoundary()
  recordsStayUnderTheCap()
  echo "test_directives ok"
