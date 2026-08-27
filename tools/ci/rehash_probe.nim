## Re-simulates a recorded replay with the NATIVE build and checks every tick's
## `gameHash` against the recording.
##
## This is the other half of the determinism gate. `tools/wasm_replay_smoke.cjs`
## proves the emscripten/wasm32 build reproduces the chain; this proves the
## RECORDING itself is reproducible from the bytes alone by a from-scratch
## simulation of the same source — which is a different claim, and the one that
## fails when the server mutates hashed state outside `sim.step` (a wall-clock
## stop banked outside the step, a record applied on one side only, a leave
## shifting the roster). Running both against the SAME replay says which side a
## divergence is on.
##
##   nim r --hints:off -d:release --path:src tools/ci/rehash_probe.nim <replay>

import std/[os, strutils]
import grf_football/[replays, sim]

when isMainModule:
  if paramCount() < 1:
    quit("usage: rehash_probe <replay> [maxTicks]", 2)
  let data = loadReplay(paramStr(1))
  var config = defaultGameConfig()
  config.update(data.configJson)
  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var player = initReplayPlayer(data)
  player.mismatchQuit = false
  let limit =
    if paramCount() >= 2: parseInt(paramStr(2)) else: high(int)
  let maxTick = player.replayMaxTick()
  while player.hashIndex < data.hashes.len and sim.tickCount < maxTick and
      sim.tickCount < limit:
    player.stepReplay(sim)
    if player.hashValidationFailed:
      quit("NATIVE re-simulation diverged at tick " &
        $player.hashMismatchTick & " of " & $maxTick, 1)
  echo "native re-simulation matched ", player.hashIndex, " of ",
    data.hashes.len, " recorded ticks (to tick ", sim.tickCount, ")"
