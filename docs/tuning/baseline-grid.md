# `zonal` parameter grid — 2026-08-27

The artifact of `tools/tune_baselines.nim`, the grid harness for the `zonal`
baseline's three free parameters. Re-run it after any physics change and replace
this file; `ZonalTuned` in `src/grf_football/baselines.nim` must always be a row
in the table below.

```
nim r --hints:off -d:release --path:src tools/tune_baselines.nim
```

## Method

- **Grid.** press radius ∈ {9, 12, 15, 18, 21} m × shoot range ∈
  {16, 20, 24, 28} m × pressure radius ∈ {1.5, 2.5, 3.5} m = **60 points**.
- **Opponent.** the `gegenpress` filler, unchanged, at its own fixed parameters.
- **Match.** the full 5760-tick (4:00) episode through the REAL control layer,
  the same path the server takes. Judging a four-minute claim over two minutes
  measures the wrong thing: `gegenpress` fades on stamina in the third minute.
- **Split.** train seeds 679961 and 1234567, each played **both ways round**
  (zonal as red, then as blue) so a first-half kickoff cannot decide a point —
  4 matches per grid point, **240 matches** in total. Holdout seeds 20260827 and
  99991 are scored for the winner and the previous default ONLY, after the
  choice is made.
- **Score.** aggregate goals for − goals against. Ties break toward the smaller
  press radius: a tie means the extra pressing bought no goals and cost stamina.

## Result

The best eight of the 60 points:

| rank | press radius | shoot range | pressure radius | train gd |
|---|---|---|---|---|
| 1 | 12 m | 16 m | 1.5 m | +5 |
| 2 | 18 m | 28 m | 1.5 m | +5 |
| 3 | 18 m | 28 m | 2.5 m | +5 |
| 4 | 18 m | 16 m | 2.5 m | +4 |
| 5 | 18 m | 16 m | 3.5 m | +4 |
| 6 | 15 m | 28 m | 1.5 m | +3 |
| 7 | 15 m | 28 m | 2.5 m | +3 |
| 8 | 18 m | 16 m | 1.5 m | +3 |

Holdout, never used to choose:

| point | goals | holdout gd |
|---|---|---|
| **press 12 m, shoot 16 m, pressure 1.5 m** (the winner) | 8-0 | **+8** |
| press 15 m, shoot 20 m, pressure 2.5 m (the previous default) | 7-5 | +2 |

So `ZonalTuned` is

```nim
ZonalTuned* = ZonalParams(
  pressRadius: 12_000_000'i32,
  shootRange: 16_000_000'i32,
  pressureRadius: 1_500_000'i32)
```

**This is a deviation from the design note**, which names 15 m / 20 m / 2.5 m
for `zonal` (design.md:582-587). Those three numbers were guessed; these were
measured. The note's point scores −1 on the train split — it LOSES to
`gegenpress` on those two seeds — and +2 on the holdout; the winner scores +5
and +8. The direction is consistent: press tighter, and shoot only from inside
16 m. A shot from 20-28 m is a turnover in this physics (the keeper catches
anything at or under 18 m/s and the aim error grows with distance), and a 21 m
press radius pulls the shape apart.

Two of the top three points are the opposite corner (18 m press, 28 m shoot).
That is why the holdout split exists: the winner is the point that also wins on
seeds it never saw.

## Full grid (train split)

| press radius | shoot range | pressure radius | goals for | goals against | train gd |
|---|---|---|---|---|---|
| 9 m | 16 m | 1.5 m | 5 | 4 | +1 |
| 9 m | 16 m | 2.5 m | 4 | 5 | -1 |
| 9 m | 16 m | 3.5 m | 4 | 4 | +0 |
| 9 m | 20 m | 1.5 m | 4 | 5 | -1 |
| 9 m | 20 m | 2.5 m | 5 | 7 | -2 |
| 9 m | 20 m | 3.5 m | 5 | 7 | -2 |
| 9 m | 24 m | 1.5 m | 5 | 5 | +0 |
| 9 m | 24 m | 2.5 m | 6 | 7 | -1 |
| 9 m | 24 m | 3.5 m | 6 | 7 | -1 |
| 9 m | 28 m | 1.5 m | 4 | 5 | -1 |
| 9 m | 28 m | 2.5 m | 6 | 5 | +1 |
| 9 m | 28 m | 3.5 m | 5 | 7 | -2 |
| 12 m | 16 m | 1.5 m | 9 | 4 | +5 |
| 12 m | 16 m | 2.5 m | 7 | 6 | +1 |
| 12 m | 16 m | 3.5 m | 6 | 5 | +1 |
| 12 m | 20 m | 1.5 m | 2 | 5 | -3 |
| 12 m | 20 m | 2.5 m | 3 | 7 | -4 |
| 12 m | 20 m | 3.5 m | 3 | 7 | -4 |
| 12 m | 24 m | 1.5 m | 5 | 5 | +0 |
| 12 m | 24 m | 2.5 m | 6 | 7 | -1 |
| 12 m | 24 m | 3.5 m | 6 | 7 | -1 |
| 12 m | 28 m | 1.5 m | 5 | 4 | +1 |
| 12 m | 28 m | 2.5 m | 5 | 6 | -1 |
| 12 m | 28 m | 3.5 m | 5 | 5 | +0 |
| 15 m | 16 m | 1.5 m | 5 | 5 | +0 |
| 15 m | 16 m | 2.5 m | 5 | 6 | -1 |
| 15 m | 16 m | 3.5 m | 4 | 5 | -1 |
| 15 m | 20 m | 1.5 m | 4 | 5 | -1 |
| 15 m | 20 m | 2.5 m | 4 | 5 | -1 |
| 15 m | 20 m | 3.5 m | 3 | 7 | -4 |
| 15 m | 24 m | 1.5 m | 5 | 5 | +0 |
| 15 m | 24 m | 2.5 m | 5 | 5 | +0 |
| 15 m | 24 m | 3.5 m | 3 | 7 | -4 |
| 15 m | 28 m | 1.5 m | 6 | 3 | +3 |
| 15 m | 28 m | 2.5 m | 6 | 3 | +3 |
| 15 m | 28 m | 3.5 m | 5 | 4 | +1 |
| 18 m | 16 m | 1.5 m | 8 | 5 | +3 |
| 18 m | 16 m | 2.5 m | 9 | 5 | +4 |
| 18 m | 16 m | 3.5 m | 9 | 5 | +4 |
| 18 m | 20 m | 1.5 m | 1 | 8 | -7 |
| 18 m | 20 m | 2.5 m | 1 | 8 | -7 |
| 18 m | 20 m | 3.5 m | 2 | 8 | -6 |
| 18 m | 24 m | 1.5 m | 4 | 6 | -2 |
| 18 m | 24 m | 2.5 m | 3 | 6 | -3 |
| 18 m | 24 m | 3.5 m | 2 | 6 | -4 |
| 18 m | 28 m | 1.5 m | 8 | 3 | +5 |
| 18 m | 28 m | 2.5 m | 8 | 3 | +5 |
| 18 m | 28 m | 3.5 m | 7 | 4 | +3 |
| 21 m | 16 m | 1.5 m | 7 | 6 | +1 |
| 21 m | 16 m | 2.5 m | 6 | 6 | +0 |
| 21 m | 16 m | 3.5 m | 6 | 6 | +0 |
| 21 m | 20 m | 1.5 m | 1 | 7 | -6 |
| 21 m | 20 m | 2.5 m | 1 | 7 | -6 |
| 21 m | 20 m | 3.5 m | 2 | 6 | -4 |
| 21 m | 24 m | 1.5 m | 3 | 6 | -3 |
| 21 m | 24 m | 2.5 m | 3 | 6 | -3 |
| 21 m | 24 m | 3.5 m | 3 | 5 | -2 |
| 21 m | 28 m | 1.5 m | 5 | 3 | +2 |
| 21 m | 28 m | 2.5 m | 5 | 3 | +2 |
| 21 m | 28 m | 3.5 m | 5 | 3 | +2 |
