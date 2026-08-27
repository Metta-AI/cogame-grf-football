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
  let config = testConfig(maxTicks = 1440)
  let path = tempPath("episode.replay")
  removeFile(path)
  let recorded = recordEpisode(config, path)
  doAssert fileExists(path), "the episode wrote a replay"
  doAssert getFileSize(path) > 5000, "the replay is not a stub"
  doAssert recorded.hashes.len > 1400, "the episode played out"

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
  doAssert ticks > 1400, "the re-simulation walked the whole match"
  removeFile(path)
  report "an episode round-trips through the replay with an identical chain"

proc recordsStayUnderTheCap() =
  let config = testConfig(maxTicks = 1440)
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

proc theRenderPathDoesNotPerturbTheSim() =
  ## The server does three things to the sim each tick that no test harness
  ## did: it derives broadcast events, it builds a sprite packet per seat, and
  ## it builds the chrome frame — and two of those take `var SimServer`. A
  ## hosted recording diverged from its own re-simulation at a throw-in, so
  ## this plays an episode through ALL of it and then re-simulates the bytes.
  let config = testConfig(maxTicks = 1440)
  let path = tempPath("episode-render.replay")
  removeFile(path)
  var sim = seatedSim(config)
  sim.warmBoardRenderCaches()
  var writer = openReplayWriter(path, config.configJson())
  writer.lastMasks = newSeq[uint8](CogCount)
  for seat in 0 ..< SeatCount:
    writer.writeJoin(tickTime(sim.tickCount), seat, "policy-" & $seat, seat,
      "t" & $seat)
  var
    tracker = initBroadcastTracker()
    viewers: array[SeatCount, PlayerViewerState]
    prev = newSeq[uint8](CogCount)
    guard = 0
  for seat in 0 ..< SeatCount:
    viewers[seat] = initPlayerViewerState()
  while sim.phase != GameOver and guard < config.maxTicks * 3 + 5000:
    inc guard
    if sim.phase == Playing:
      let elapsed = sim.tickCount - sim.gameStartTick
      if elapsed mod sim.turnTicks() == 0 or not sim.hasDirective[0]:
        let turn = elapsed div sim.turnTicks()
        for seat in 0 ..< SeatCount:
          let d = sim.zonalDirective(seat, turn)
          sim.activeDirective[seat] = d
          sim.hasDirective[seat] = true
          let record = capRecord($directiveJson(seat, d))
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
    let events = newJArray()
    sim.stepEvents(tracker, events)
    for seat in 0 ..< SeatCount:
      var next: PlayerViewerState
      discard sim.buildSpriteProtocolPlayerUpdates(seat, viewers[seat], next)
      viewers[seat] = next
    discard sim.buildStateJson(events, true, 1, config.maxTicks, false, false,
      -1, -1)
  writer.writeChat(tickTime(sim.tickCount), 0, capRecord(sim.resultRecordJson()))
  writer.closeReplayWriter()

  let data = loadReplay(path)
  var replayConfig = defaultGameConfig()
  replayConfig.update(data.configJson)
  var replaySim = initSimServer(replayConfig)
  replaySim.gameEventLoggingEnabled = false
  var player = initReplayPlayer(data)
  player.mismatchQuit = false
  while player.hashIndex < data.hashes.len and
      replaySim.tickCount < player.replayMaxTick():
    player.stepReplay(replaySim)
    doAssert not player.hashValidationFailed,
      "the recording diverged from its own re-simulation at tick " &
        $player.hashMismatchTick & " — the render path perturbed the sim"
  removeFile(path)
  report "the broadcast and render path does not perturb the sim"

proc everyEndReasonReDerives() =
  ## THE RECORD -> RE-DERIVE TEST FOR EVERY END REASON, not just `complete`.
  ## A wall-clock stop and a host error are wall-clock FACTS: nothing in sim
  ## state implies them, so banking them outside `sim.step` and then writing
  ## that tick's hash made every `deadline` replay diverge at the stop tick
  ## (playbooks/make-coworld.md, particle-worlds). They travel as a `stop`
  ## record and are re-applied through the same `finishGame`.
  for (reason, rule) in [("deadline", "wall_clock"), ("fault", "host_error"),
      ("fault", "sim_fault")]:
    let config = testConfig(maxTicks = 1440)
    let path = tempPath("episode-" & rule & ".replay")
    removeFile(path)
    var sim = seatedSim(config)
    var writer = openReplayWriter(path, config.configJson())
    writer.lastMasks = newSeq[uint8](CogCount)
    for seat in 0 ..< SeatCount:
      writer.writeJoin(tickTime(sim.tickCount), seat, "policy-" & $seat, seat,
        "t" & $seat)
    var prev = newSeq[uint8](CogCount)
    var guard = 0
    var stopped = false
    while sim.phase != GameOver and guard < config.maxTicks * 3 + 5000:
      inc guard
      if sim.phase == Playing:
        let elapsed = sim.tickCount - sim.gameStartTick
        if elapsed mod sim.turnTicks() == 0 or not sim.hasDirective[0]:
          for seat in 0 ..< SeatCount:
            sim.activeDirective[seat] =
              sim.zonalDirective(seat, elapsed div sim.turnTicks())
            sim.hasDirective[seat] = true
        # The stop lands mid-match, exactly as the engine's would.
        if elapsed >= 600 and not stopped:
          stopped = true
          let record = capRecord($(%*{
            "k": "stop", "reason": reason, "rule": rule,
            "tick": sim.tickCount}))
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
    doAssert stopped, "the stop record was never written"
    doAssert reasonText(sim.endReason) == reason,
      "the recorded stop must set reason " & reason & ", got " &
        reasonText(sim.endReason)
    doAssert endRuleText(sim.endRule) == rule
    writer.writeChat(tickTime(sim.tickCount), 0,
      capRecord(sim.resultRecordJson()))
    writer.closeReplayWriter()

    let data = loadReplay(path)
    var replayConfig = defaultGameConfig()
    replayConfig.update(data.configJson)
    var replaySim = initSimServer(replayConfig)
    replaySim.gameEventLoggingEnabled = false
    var player = initReplayPlayer(data)
    player.mismatchQuit = false
    while player.hashIndex < data.hashes.len and
        replaySim.tickCount < player.replayMaxTick():
      player.stepReplay(replaySim)
      doAssert not player.hashValidationFailed,
        "a " & reason & "/" & rule & " episode diverged at tick " &
          $player.hashMismatchTick & " — the stop is not re-derivable"
    doAssert reasonText(replaySim.endReason) == reason,
      "playback must re-derive reason " & reason
    doAssert endRuleText(replaySim.endRule) == rule,
      "playback must re-derive endRule " & rule
    removeFile(path)
  report "every end reason is recorded as a record and re-derives exactly"

when isMainModule:
  echo "test_replay"
  episodeRoundTrips()
  everyEndReasonReDerives()
  theRenderPathDoesNotPerturbTheSim()
  recordsStayUnderTheCap()
  resultRecordEqualsTheResults()
  echo "test_replay ok"
