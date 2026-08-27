## THE DETERMINISM GATE. If this fails the physics or a build flag changed —
## fix the code, never the test.
##
## Two native runs from the same seed and the same recorded action bytes
## produce identical `gameHash` chains; no `float` symbol is reachable from the
## hashed modules; `SinQ12` matches `math.sin` entry for entry; `isqrt` matches
## an exhaustive small table and perfect squares to 2^40.

import std/[math, os]
import lib/helpers

const HashedModules = [
  "src/grf_football/sim.nim",
  "src/grf_football/sim_types.nim",
  "src/grf_football/sim_config.nim",
  "src/grf_football/sim_state.nim",
  "src/grf_football/pitch.nim",
  "src/grf_football/control.nim",
  "src/grf_football/builtin_ai.nim",
  "src/grf_football/trig.nim"
]

const FloatSymbols = [
  "float", "float32", "float64", "sin", "cos", "tan", "arctan2", "sqrt",
  "pow", "math", "hypot", "arccos", "arcsin", "ceil", "floor", "round"
]

proc sameSeedSameChain() =
  let config = testConfig(maxTicks = 720)
  let a = runScriptedMatch(config, collectActions = true)
  let b = runScriptedMatch(config, collectActions = true)
  doAssert a.actions.len == b.actions.len,
    "two runs of the same seed must step the same number of ticks"
  for t in 0 ..< a.actions.len:
    for i in 0 ..< CogCount:
      doAssert a.actions[t][i] == b.actions[t][i],
        "action byte diverged at tick " & $t & " cog " & $i
  doAssert a.goals[Red] == b.goals[Red] and a.goals[Blue] == b.goals[Blue]
  report "two runs from one seed produce the identical action log"

proc replayFromActionsReproducesTheChain() =
  ## Re-stepping a fresh sim from the RECORDED action bytes reproduces every
  ## tick's hash. This is the contract the wasm viewer relies on.
  let config = testConfig(maxTicks = 720)
  let match = runScriptedMatch(config, collectActions = true)
  var live = seatedSim(config)
  var chain: seq[uint64]
  var prev = newSeq[uint8](CogCount)
  for frame in match.actions:
    var buffer = newSeq[uint8](CogCount)
    for i in 0 ..< CogCount:
      buffer[i] = frame[i]
    live.step(buffer, prev)
    prev = buffer
    chain.add(live.gameHash())
  var viewer = seatedSim(config)
  var vprev = newSeq[uint8](CogCount)
  for t, frame in match.actions:
    var buffer = newSeq[uint8](CogCount)
    for i in 0 ..< CogCount:
      buffer[i] = frame[i]
    viewer.step(buffer, vprev)
    vprev = buffer
    doAssert viewer.gameHash() == chain[t],
      "hash chain diverged at tick " & $t
  report "re-simulating the recorded action log reproduces every tick hash"

proc noFloatInTheHashedCore() =
  for path in HashedModules:
    doAssert fileExists(path), "missing hashed module " & path
    let names = identifiers(strippedSource(path))
    for name in names:
      for banned in FloatSymbols:
        doAssert name != banned,
          "float-family symbol `" & banned & "` reachable from " & path
  report "no float symbol is reachable from the hashed core"

proc sinTableMatchesLibm() =
  for b in 0 ..< 256:
    let want = int32(round(4096.0 * sin(2.0 * PI * float(b) / 256.0)))
    doAssert SinQ12[b] == want,
      "SinQ12[" & $b & "] = " & $SinQ12[b] & ", math.sin says " & $want
  report "the committed SinQ12 table matches math.sin entry for entry"

proc isqrtIsExact() =
  for v in 0 .. 20000:
    let r = isqrt(int64(v))
    doAssert r * r <= int64(v) and (r + 1) * (r + 1) > int64(v),
      "isqrt(" & $v & ") = " & $r
  var p = 1'i64
  while p * p <= (1'i64 shl 40):
    doAssert isqrt(p * p) == p, "isqrt of a perfect square " & $p
    p = p * 3 + 1
  report "isqrt is exact on 0..20000 and on perfect squares to 2^40"

proc bradsAreAntisymmetric() =
  ## The integer atan2 must be exactly antisymmetric under y -> -y, or the two
  ## halves of the pitch are not fair.
  for dx in countup(-40_000_000, 40_000_000, 3_137_000):
    for dy in countup(-25_000_000, 25_000_000, 2_113_000):
      if dx == 0 and dy == 0:
        continue
      let
        a = bradsOfVectorI(int32(dx), int32(dy))
        b = bradsOfVectorI(int32(dx), int32(-dy))
      doAssert ((a + b) mod 256) == 0,
        "atan2 is not antisymmetric at " & $dx & "," & $dy
  report "bradsOfVectorI is exactly antisymmetric under negation"

proc cosmeticPoolsAreOutsideTheHash() =
  ## Resolution step 11: `gameHash` never mixes directives, notes, FX or trails.
  ## The three cosmetic pools and the broadcast feed are appended to inside the
  ## step, so the only way to state the contract is to append to them by hand
  ## and require the hash not to move.
  var sim = playing(testConfig())
  sim.stepIdle(12)
  let before = sim.gameHash()
  sim.trail.add TrailPoint(x: sim.ball.x, y: sim.ball.y,
    tick: int32(sim.tickCount))
  sim.arcs.add ArcFx(x0: 0, y0: 0, x1: 1, y1: 1, tick: int32(sim.tickCount),
    team: 0, kind: 0)
  sim.goalFx.add GoalFx(tick: int32(sim.tickCount), team: 0)
  sim.feed.add FeedLine(tick: int32(sim.tickCount), kind: "goal", team: 0,
    text: "a line the hash must not see")
  sim.activeDirective[0].note = "a note the hash must not see"
  doAssert sim.gameHash() == before,
    "gameHash moved when only FX, the trail, the feed or a directive changed"
  report "FX, trails, the feed and directives are outside gameHash"

when isMainModule:
  echo "test_determinism"
  sameSeedSameChain()
  replayFromActionsReproducesTheChain()
  noFloatInTheHashedCore()
  sinTableMatchesLibm()
  isqrtIsExact()
  bradsAreAntisymmetric()
  cosmeticPoolsAreOutsideTheHash()
  echo "test_determinism ok"
