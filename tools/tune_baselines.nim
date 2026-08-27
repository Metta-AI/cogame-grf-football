## THE GRID HARNESS for the `zonal` baseline's three free parameters.
##
## `zonal` is load-bearing four times over (certification player, per-turn LLM
## fallback, no-show driver, default), so its parameters must be MEASURED, not
## guessed. This tool sweeps the full grid, scores every point on a train split
## and re-scores only the winner on a holdout split, and prints the tables that
## are committed as `docs/tuning/baseline-grid.md`. The winner goes into
## `ZonalTuned` in `src/grf_football/baselines.nim`.
##
##   nim r --hints:off -d:release --path:src tools/tune_baselines.nim
##   nim r --hints:off -d:release --path:src tools/tune_baselines.nim --quick
##
## Scoring, per grid point: full-length (5760-tick) matches against the
## `gegenpress` foil, every train seed played BOTH WAYS ROUND so a first-half
## kickoff advantage cannot decide anything, aggregated as (goals for − goals
## against). Ties break toward the SMALLER press radius: a tie means the extra
## pressing bought nothing, and the tighter shape is the one that keeps its
## stamina. The holdout split is never used to choose, only to report — a point
## that wins the train split and collapses on the holdout is overfitted to two
## seeds and says so in the table.
##
## It is not run in CI: 240 full matches is ~2 minutes, and its output is an
## artifact, not an assertion. `tests/test_control.nim` is what holds the
## conclusion (`zonal` is not beaten by `gegenpress`, and a tuned all-scripted
## episode plays to full time with every order legal).

import std/[algorithm, os, strformat, strutils]
import ../tests/lib/helpers

const
  TrainSeeds = [679961, 1234567]
  HoldoutSeeds = [20260827, 99991]
  PressRadii = [9_000_000'i32, 12_000_000, 15_000_000, 18_000_000, 21_000_000]
  ShootRanges = [16_000_000'i32, 20_000_000, 24_000_000, 28_000_000]
  PressureRadii = [1_500_000'i32, 2_500_000, 3_500_000]

type Point = object
  params: ZonalParams
  goalsFor: int
  goalsAgainst: int
  matches: int

proc score(p: Point): int = p.goalsFor - p.goalsAgainst

proc metres(v: int32): string = &"{v div 1_000_000}"

proc label(params: ZonalParams): string =
  &"press {metres(params.pressRadius)} m, shoot {metres(params.shootRange)} m," &
    &" pressure {params.pressureRadius div 100_000} dm"

proc evaluate(params: ZonalParams, seeds: openArray[int],
    maxTicks: int): Point =
  ## One grid point against the `gegenpress` foil: every seed both ways round.
  result.params = params
  for seed in seeds:
    let config = testConfig(seed = seed, maxTicks = maxTicks)
    let asRed = runScriptedMatch(config, red = "zonal", blue = "gegenpress",
      zonalParams = params)
    result.goalsFor += asRed.goals[Red]
    result.goalsAgainst += asRed.goals[Blue]
    let asBlue = runScriptedMatch(config, red = "gegenpress", blue = "zonal",
      zonalParams = params)
    result.goalsFor += asBlue.goals[Blue]
    result.goalsAgainst += asBlue.goals[Red]
    result.matches += 2

proc main() =
  let quick = "--quick" in commandLineParams()
  let maxTicks = if quick: 2880 else: DefaultMaxTicks
  let seeds = if quick: [TrainSeeds[0], TrainSeeds[0]] else: TrainSeeds
  var points: seq[Point]
  var total = 0
  for pr in PressRadii:
    for sr in ShootRanges:
      for pu in PressureRadii:
        let params = ZonalParams(pressRadius: pr, shootRange: sr,
          pressureRadius: pu)
        let point = evaluate(params, seeds, maxTicks)
        total += point.matches
        points.add(point)
        echo &"{label(params):<48} {point.goalsFor:>3}-{point.goalsAgainst:<3}" &
          &" gd {score(point):>+3}"
  points.sort(proc (a, b: Point): int =
    if score(a) != score(b): return cmp(score(b), score(a))
    # A tie goes to the tighter shape: pressing that bought no goals cost
    # stamina for nothing.
    if a.params.pressRadius != b.params.pressRadius:
      return cmp(a.params.pressRadius, b.params.pressRadius)
    cmp(a.params.shootRange, b.params.shootRange))

  echo ""
  echo &"{points.len} grid points, {total} matches of {maxTicks} ticks"
  echo "| rank | press | shoot | pressure | train gd |"
  echo "|---|---|---|---|---|"
  for i in 0 ..< min(8, points.len):
    let p = points[i]
    echo &"| {i + 1} | {metres(p.params.pressRadius)} m |" &
      &" {metres(p.params.shootRange)} m |" &
      &" {p.params.pressureRadius div 100_000} dm | {score(p):+} |"

  let winner = points[0]
  let default = ZonalParams(pressRadius: 15_000_000'i32,
    shootRange: 20_000_000'i32, pressureRadius: 2_500_000'i32)
  echo ""
  echo "holdout (never used to choose):"
  for params in [winner.params, default]:
    let h = evaluate(params, HoldoutSeeds, maxTicks)
    echo &"  {label(params):<48} {h.goalsFor:>3}-{h.goalsAgainst:<3}" &
      &" gd {score(h):>+3}"
  echo ""
  echo "ZonalTuned = ZonalParams(",
    &"pressRadius: {winner.params.pressRadius}'i32, ",
    &"shootRange: {winner.params.shootRange}'i32, ",
    &"pressureRadius: {winner.params.pressureRadius}'i32)"

when isMainModule:
  main()
