## STRICT-UTF-8 REPLAY PARSE: `tools/replay_summary.py` run over the episode's
## bytes emits a document a strict parser accepts, and every recorded string
## decodes as UTF-8 with `errors="strict"` — including one seeded with a 4-byte
## emoji sitting exactly on a cap boundary.

import std/[json, os, osproc, strutils, unicode]
import lib/helpers

proc emojiNote(): string =
  var note = ""
  for _ in 0 ..< (MaxNoteRunes - 1):
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
    doAssert isValidUtf8(d{"note"}.getStr)
    doAssert d{"note"}.getStr.runeLen <= MaxNoteRunes
  doAssert sawEmoji, "the seeded 4-byte emoji did not survive to the replay"
  removeFile(path)
  report "replay_summary.py emits strict-UTF-8 JSON with the emoji intact"

when isMainModule:
  echo "test_replay_utf8"
  summaryIsStrictUtf8Json()
  echo "test_replay_utf8 ok"
