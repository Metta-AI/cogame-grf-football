## END-TO-END: a scripted episode written to a replay, re-simulated to an
## identical hash chain, with every record inside its cap and the `result`
## record equal to `playerResultsJson()`.

import std/[json, os, unicode]
import lib/helpers

proc recordEpisode(config: GameConfig, path: string):
    tuple[hashes: seq[uint64], results: string, records: seq[string]] =
  ## Plays a whole scripted episode through the real writer, exactly as the
  ## server does: action bytes in, hash per tick, records into the chat stream.
  var sim = seatedSim(config)
  var writer = openReplayWriter(path, config.configJson())
  writer.lastMasks = newSeq[uint8](CogCount)
  for seat in 0 ..< SeatCount:
    writer.writeJoin(tickTime(sim.tickCount), seat, "policy-" & $seat, seat,
      "t" & $seat)
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
          let d = sim.zonalDirective(seat, turn)
          sim.activeDirective[seat] = d
          sim.hasDirective[seat] = true
          let record = capRecord($directiveJson(seat, d))
          result.records.add(record)
          writer.writeChat(tickTime(sim.tickCount), 0, record)
          sim.applyRecord(record)
    let actions = sim.compileActions(sim.activeDirective)
    writer.writeInputFrameMasks(tickTime(sim.tickCount), actions)
    var buffer = newSeq[uint8](CogCount)
    for i in 0 ..< CogCount:
      buffer[i] = actions[i]
    sim.step(buffer, prev)
    prev = buffer
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())
    result.hashes.add(sim.gameHash())
  result.results = sim.playerResultsJson()
  let resultRecord = capRecord(sim.resultRecordJson())
  result.records.add(resultRecord)
  writer.writeChat(tickTime(sim.tickCount), 0, resultRecord)
  writer.closeReplayWriter()

proc episodeRoundTrips() =
  let config = testConfig(maxTicks = 720)
  let path = tempPath("episode.replay")
  removeFile(path)
  let recorded = recordEpisode(config, path)
  doAssert fileExists(path), "the episode wrote a replay"
  doAssert getFileSize(path) > 5000, "the replay is not a stub"
  doAssert recorded.hashes.len > 700, "the episode played out"

  # Re-simulate from the bytes and compare every tick.
  let data = loadReplay(path)
  var runtime = initReplayRuntime(data, mismatchQuit = true,
    gameEventLoggingEnabled = false)
  runtime.player.buildReplayKeyframes(initSimServer(runtime.config))
  doAssert runtime.player.replayMaxTick() >= recorded.hashes.len - 1,
    "the replay carries the whole match"

  var sim = initSimServer(runtime.config)
  sim.gameEventLoggingEnabled = false
  var player = initReplayPlayer(data)
  player.mismatchQuit = true
  var ticks = 0
  while player.hashIndex < data.hashes.len and
      sim.tickCount < player.replayMaxTick():
    player.stepReplay(sim)
    inc ticks
  doAssert not player.hashValidationFailed,
    "the hash chain diverged at tick " & $player.hashMismatchTick
  doAssert ticks > 700, "the re-simulation walked the whole match"
  removeFile(path)
  report "an episode round-trips through the replay with an identical chain"

proc recordsStayUnderTheCap() =
  let config = testConfig(maxTicks = 720)
  let path = tempPath("episode-caps.replay")
  removeFile(path)
  let recorded = recordEpisode(config, path)
  var directives = 0
  for record in recorded.records:
    doAssert record.runeLen <= MaxDirectiveRecordRunes,
      "a record is over the 900-rune cap: " & $record.runeLen
    doAssert isValidUtf8(record), "a record is not valid UTF-8"
    let node = parseJson(record)
    if node{"k"}.getStr == "directive":
      inc directives
      doAssert node{"note"}.getStr.runeLen <= MaxNoteRunes
      for entry in node{"cogs"}:
        doAssert entry{"say"}.getStr.runeLen <= MaxSayRunes
  doAssert directives >= SeatCount, "the episode wrote directive records"
  removeFile(path)
  report "every directive record is <= 900 runes and valid UTF-8"

proc resultRecordEqualsTheResults() =
  let config = testConfig(maxTicks = 480)
  let path = tempPath("episode-result.replay")
  removeFile(path)
  let recorded = recordEpisode(config, path)
  let last = parseJson(recorded.records[^1])
  doAssert last{"k"}.getStr == "result", "the last record is the result"
  doAssert last{"results"} == parseJson(recorded.results),
    "the `result` record must equal playerResultsJson() exactly"
  removeFile(path)
  report "the result record equals playerResultsJson()"

when isMainModule:
  echo "test_replay"
  episodeRoundTrips()
  recordsStayUnderTheCap()
  resultRecordEqualsTheResults()
  echo "test_replay ok"
