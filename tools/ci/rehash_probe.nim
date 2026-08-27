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

import std/[json, os, strutils, tables]
import grf_football/[replays, sim]

proc recordedDigests(data: ReplayData): Table[int, string] =
  ## The server's own state checkpoints, keyed by tick.
  result = initTable[int, string]()
  for chat in data.chats:
    if "\"k\":\"state\"" notin chat.message:
      continue
    try:
      let node = parseJson(chat.message)
      if node{"k"}.getStr == "state":
        result[node{"t"}.getInt] = node{"d"}.getStr
    except CatchableError:
      discard

proc reportDigestDiff(tick: int, recorded, derived: string) =
  ## Names every field the re-simulation disagrees with the recording on.
  var
    want = initTable[string, string]()
    order: seq[string]
  for pair in recorded.split(';'):
    if pair.len == 0: continue
    let cut = pair.find('=')
    if cut <= 0: continue
    want[pair[0 ..< cut]] = pair[cut + 1 .. pair.high]
    order.add(pair[0 ..< cut])
  var got = initTable[string, string]()
  for pair in derived.split(';'):
    if pair.len == 0: continue
    let cut = pair.find('=')
    if cut <= 0: continue
    got[pair[0 ..< cut]] = pair[cut + 1 .. pair.high]
  var differing: seq[string]
  for key in order:
    let mine = got.getOrDefault(key, "<missing>")
    if mine != want[key]:
      differing.add(key & ": recorded " & want[key] & ", re-derived " & mine)
  echo "state checkpoint at tick ", tick, ": ", differing.len,
    " field(s) differ"
  for line in differing:
    echo "  ", line

when isMainModule:
  if paramCount() < 1:
    quit("usage: rehash_probe <replay> [maxTicks]", 2)
  let data = loadReplay(paramStr(1))
  var config = defaultGameConfig()
  config.update(data.configJson)
  # `game`, not `sim`: `sim` is the imported MODULE's name here.
  var game = initSimServer(config)
  game.gameEventLoggingEnabled = false
  var player = initReplayPlayer(data)
  player.mismatchQuit = false
  let limit =
    if paramCount() >= 2: parseInt(paramStr(2)) else: high(int)
  let
    maxTick = player.replayMaxTick()
    digests = recordedDigests(data)
  echo "recorded state checkpoints: ", digests.len
  var reported = false
  while player.hashIndex < data.hashes.len and game.tickCount < maxTick and
      game.tickCount < limit:
    player.stepReplay(game)
    if digests.hasKey(game.tickCount):
      let derived = game.stateDigest()
      if derived != digests[game.tickCount]:
        reportDigestDiff(game.tickCount, digests[game.tickCount], derived)
        reported = true
    if player.hashValidationFailed:
      if not reported:
        echo "the chain diverged BETWEEN checkpoints; the next checkpoint " &
          "after tick ", player.hashMismatchTick, " will name the fields"
      # Keep walking to the next checkpoint so the fields get named, then stop.
      var walked = 0
      while walked < StateDigestTicks * 2 and game.tickCount < maxTick:
        player.stepReplay(game)
        inc walked
        if digests.hasKey(game.tickCount):
          reportDigestDiff(game.tickCount, digests[game.tickCount],
            game.stateDigest())
          break
      quit("NATIVE re-simulation diverged at tick " &
        $player.hashMismatchTick & " of " & $maxTick, 1)
  echo "native re-simulation matched ", player.hashIndex, " of ",
    data.hashes.len, " recorded ticks (to tick ", game.tickCount, ")"
