## RELEASE-ONLY. A whole match of physics, the control layer AND THE SERVE PATH
## must finish well inside the episode's budget: 5760 ticks in under 120 s,
## which is four times the 30 s target and still an order of magnitude inside
## the engine's 690 s wall-clock stop.
##
## The serve half is not optional. The reviewed sha's docker-smoke episode ended
## `deadline` with `sim 0 ms, render 178262 ms` — 124 ms a tick, all of it in
## the eight `buildSpriteProtocolPlayerUpdates` calls the server makes per tick,
## and none of it visible to a bound that measured physics and control only.
## What this test steps is what `server.nim:717-800` steps: the turn, the
## control compile, `sim.step`, `stepEvents`, one sprite packet per seat, and
## the chrome frame.

import std/[json, monotimes, times]
import lib/helpers

proc runServedMatch(config: GameConfig): tuple[ticks: int, ms: int64,
    simMs: int64, serveMs: int64] =
  var sim = seatedSim(config)
  sim.warmBoardRenderCaches()
  var
    tracker = initBroadcastTracker()
    viewers: array[SeatCount, PlayerViewerState]
    prev = newSeq[uint8](CogCount)
    guard = 0
    simUs, serveUs: int64
  for seat in 0 ..< SeatCount:
    viewers[seat] = initPlayerViewerState()
  let started = getMonoTime()
  while sim.phase != GameOver and guard < config.maxTicks * 3 + 5000:
    inc guard
    if sim.phase == Playing:
      let elapsed = sim.tickCount - sim.gameStartTick
      if elapsed mod sim.turnTicks() == 0 or not sim.hasDirective[0]:
        let turn = elapsed div sim.turnTicks()
        for seat in 0 ..< SeatCount:
          sim.activeDirective[seat] = sim.zonalDirective(seat, turn)
          sim.hasDirective[seat] = true
    let simStart = getMonoTime()
    let actions = sim.compileActions(sim.activeDirective)
    var buffer = newSeq[uint8](CogCount)
    for i in 0 ..< CogCount:
      buffer[i] = actions[i]
    sim.step(buffer, prev)
    prev = buffer
    discard sim.gameHash()
    simUs += (getMonoTime() - simStart).inMicroseconds

    let serveStart = getMonoTime()
    let events = newJArray()
    sim.stepEvents(tracker, events)
    for seat in 0 ..< SeatCount:
      var next: PlayerViewerState
      discard sim.buildSpriteProtocolPlayerUpdates(seat, viewers[seat], next)
      viewers[seat] = next
    discard sim.buildStateJson(events, true, 1, config.maxTicks, false, false,
      -1, -1)
    serveUs += (getMonoTime() - serveStart).inMicroseconds
  (sim.tickCount, (getMonoTime() - started).inMilliseconds,
   simUs div 1000, serveUs div 1000)

when isMainModule:
  echo "test_perf"
  let config = testConfig(maxTicks = DefaultMaxTicks)
  let served = runServedMatch(config)
  echo "  5760 ticks served in ", served.ms, " ms (sim ", served.simMs,
    " ms, serve ", served.serveMs, " ms)"
  doAssert served.ticks >= DefaultMaxTicks,
    "the match must play out, got " & $served.ticks & " ticks"
  doAssert served.ms < 120_000,
    "a full served match took " & $served.ms & " ms; the bound is 120 s"
  report "5760 ticks of physics, control AND serve inside 120 s"
  echo "test_perf ok"
