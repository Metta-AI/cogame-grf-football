## STRICT-UTF-8 REPLAY PARSE: `tools/replay_summary.py` run over the episode's
## bytes emits a document a strict parser accepts, and every recorded string
## decodes as UTF-8 with `errors="strict"` — including one seeded with a 4-byte
## emoji sitting exactly on a cap boundary.

import std/[json, os, osproc, strutils, unicode]
import lib/helpers

proc emojiNote(): string =
  var note = ""
  # The emoji must land ON the boundary rune the clip KEEPS: clipRunes takes
  # runes 0 .. maxRunes-2 and appends an ellipsis, so rune index maxRunes-2 is
  # the last one to survive.
  for _ in 0 ..< (MaxNoteRunes - 2):
    note.add("z")
  note.add("\xF0\x9F\x8F\x86")     ## U+1F3C6 TROPHY, four bytes
  note.add(" and a tail that must be cut")
  clipRunes(note, MaxNoteRunes)

proc writeEpisode(path: string): string =
  ## A short scripted episode whose FIRST directive record carries a note whose
  ## cap boundary lands on a 4-byte emoji.
  let config = testConfig(maxTicks = 480)
  var sim = seatedSim(config)
  var writer = openReplayWriter(path, config.configJson())
  writer.lastMasks = newSeq[uint8](CogCount)
  for seat in 0 ..< SeatCount:
    writer.writeJoin(tickTime(sim.tickCount), seat, "policy-" & $seat, seat,
      "t" & $seat)
    writer.writeChat(tickTime(sim.tickCount), 0, capRecord($(%*{
      "k": "register", "seat": seat,
      "team": teamText(teamOfSeat(seat)),
      "shirt": int(SeatShirt[seat]),
      "id": cogId(cogOfSeat(seat)),
      "policy": "grf-football-zonal \xF0\x9F\x8F\x86",
      "kind": "scripted", "baseline": "zonal"})))
  var prev = newSeq[uint8](CogCount)
  var guard = 0
  var seeded = false
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
          var d = sim.zonalDirective(seat, turn)
          if not seeded:
            d.note = emojiNote()
            d.cog.say = clipRunes("\xF0\x9F\x8F\x86 goal", MaxSayRunes)
          sim.activeDirective[seat] = d
          sim.hasDirective[seat] = true
          writer.writeChat(tickTime(sim.tickCount), 0,
            capRecord($directiveJson(seat, d)))
        seeded = true
    let actions = sim.compileActions(sim.activeDirective)
    writer.writeInputFrameMasks(tickTime(sim.tickCount), actions)
    var buffer = newSeq[uint8](CogCount)
    for i in 0 ..< CogCount:
      buffer[i] = actions[i]
    sim.step(buffer, prev)
    prev = buffer
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
  result = sim.playerResultsJson()
  writer.writeChat(tickTime(sim.tickCount), 0, capRecord(sim.resultRecordJson()))
  writer.closeReplayWriter()

proc summaryIsStrictUtf8Json() =
  let path = tempPath("utf8.replay")
  removeFile(path)
  discard writeEpisode(path)
  doAssert fileExists(path)
  let script = "tools/replay_summary.py"
  doAssert fileExists(script), "tools/replay_summary.py is missing"
  let (output, code) = execCmdEx("python3 " & script & " " & path)
  doAssert code == 0, "replay_summary.py failed: " & output
  doAssert isValidUtf8(output), "the summary is not valid UTF-8"
  let node = parseJson(output)
  doAssert node{"protocol"}.getStr == "grf-football/v1",
    "protocol is " & node{"protocol"}.getStr
  doAssert node{"numAgents"}.getInt == SeatCount
  doAssert node{"utf8Repairs"}.getInt == 0,
    "the writer emitted a string that is not valid UTF-8"
  doAssert node{"tickCount"}.getInt > 400
  doAssert node{"directives"}.len >= SeatCount
  doAssert node{"results"}.kind == JObject
  # Every recorded string in the summary is valid UTF-8 by construction of the
  # parse above; assert the SEEDED one survived intact.
  var sawEmoji = false
  for d in node{"directives"}:
    if "\xF0\x9F\x8F\x86" in d{"note"}.getStr:
      sawEmoji = true
    for say in d{"says"}:
      if "\xF0\x9F\x8F\x86" in say.getStr:
        sawEmoji = true
    doAssert isValidUtf8(d{"note"}.getStr)
    doAssert d{"note"}.getStr.runeLen <= MaxNoteRunes
  doAssert sawEmoji, "the seeded 4-byte emoji did not survive to the replay"
  removeFile(path)
  report "replay_summary.py emits strict-UTF-8 JSON with the emoji intact"

proc detailOf(body: string, code: int): string =
  ## The message `completionText` raises on an error code — the string
  ## `decide.nim` puts into `fallback.detail` and the replay writer records.
  let client = newLlmClient(testConfig())
  try:
    discard client.completionText(code, body)
  except GrfFootballError as failure:
    return failure.msg
  doAssert false, "completionText must raise on code " & $code
  ""

proc errorDetailIsRuneSafe() =
  ## The path llm.nim -> GrfFootballError.msg -> decide's `fallback.detail` ->
  ## the replay used to slice the HTTP body by BYTE index (400/300/160), which
  ## docs/RULES.md and AGENTS.md rule 2 forbid on any path to the replay. Every
  ## input below is chosen so the OLD byte-slice point falls in the middle of a
  ## 4-byte character; a mid-rune cut re-encodes as U+00F0 ("\xC3\xB0"), so the
  ## absence of that sequence is the assertion that the truncation is on rune
  ## boundaries and not merely repaired after the fact.
  const
    Trophy = "\xF0\x9F\x8F\x86"    ## U+1F3C6, four bytes
    Mojibake = "\xC3\xB0"          ## U+00F0, what a cut 0xF0 lead re-encodes to
  var emoji = "{}"                 ## two ASCII bytes: every later cut is odd
  for _ in 0 ..< 600:
    emoji.add(Trophy)
  for (code, cap) in [(401, 400), (429, 300), (500, 300)]:
    let detail = detailOf(emoji, code)
    doAssert isValidUtf8(detail), "the detail for " & $code & " is not UTF-8"
    doAssert detail.validateUtf8() == -1, "std/unicode agrees, for " & $code
    doAssert Mojibake notin detail,
      "the detail for " & $code & " was cut mid-rune"
    doAssert Trophy in detail, "the detail for " & $code & " kept no text"
    doAssert detail.runeLen <= cap + 64,
      "the detail for " & $code & " is " & $detail.runeLen & " runes"
    let recorded = clipRunes(detail, MaxDetailRunes)
    doAssert isValidUtf8(recorded) and recorded.runeLen <= MaxDetailRunes
    doAssert Mojibake notin recorded

  # The no-JSON path: prose with no `{`, over the 160-byte head cut.
  var prose = "!"
  for _ in 0 ..< 100:
    prose.add(Trophy)
  var noJson = ""
  try:
    discard extractJsonObject(prose)
  except GrfFootballError as failure:
    noJson = failure.msg
  doAssert noJson.len > 0, "extractJsonObject must raise on prose"
  doAssert isValidUtf8(noJson) and Mojibake notin noJson,
    "the no-JSON head was cut mid-rune"

  # And an input that is ALREADY byte-truncated — the reviewer's open question:
  # a lead byte whose continuation bytes are missing must not raise a Defect in
  # either build, and must not reach the replay as invalid UTF-8.
  let truncated = detailOf("{}" & repeat("a", 396) & Trophy[0 ..< 2], 429)
  doAssert isValidUtf8(truncated), "a byte-truncated body produced bad UTF-8"
  doAssert isValidUtf8(clipRunes(truncated, MaxDetailRunes))
  report "every captured error detail is truncated on rune boundaries"

when isMainModule:
  echo "test_replay_utf8"
  summaryIsStrictUtf8Json()
  errorDetailIsRuneSafe()
  echo "test_replay_utf8 ok"
