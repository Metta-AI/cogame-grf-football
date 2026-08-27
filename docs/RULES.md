# grf-football — rules

**grf-football is eleven-a-side association football** on an 84 m × 54 m pitch
in a continuous 2D top-down physics world. Twenty-two wheeled cogs and one
ball; the ball can leave the pitch (throw-ins, corners, goal kicks); goals win
the match. It reimplements the *spirit* of Google Research Football — 11 v 11,
a nineteen-action discrete vocabulary, and unseated players run by the engine's
built-in AI — as a new physics game written for this coworld.

## Seats

`num_agents` is **8**. Four seats per team; each seat commands exactly one
outfield shirt for the whole match. The other seven shirts on each side —
including the keeper — are driven by the engine's built-in AI.

| seat | team | shirt | role |
|---|---|---|---|
| 0 | red | `RED-10` | playmaker |
| 1 | blue | `BLUE-10` | playmaker |
| 2 | red | `RED-9` | striker |
| 3 | blue | `BLUE-9` | striker |
| 4 | red | `RED-7` | winger |
| 5 | blue | `BLUE-7` | winger |
| 6 | red | `RED-6` | anchor |
| 7 | blue | `BLUE-6` | anchor |

Seat → team → shirt is derived from the seat index alone, so it needs no
config: seat parity **is** the team. A seat does not drive a joystick. Every
ten seconds of match time it issues **one order** for its shirt, and a
deterministic control layer executes it for the next ten seconds. See
[COACHING.md](COACHING.md).

## The pitch

All world quantities are integer **micrometres** (µm) and **µm per tick**. The
coordinates a policy sees are **view coordinates**: metres from the centre
spot, `X = (x − 45 m)`, `Y = (y − 30 m)`, so the pitch is X ∈ [−42, +42],
Y ∈ [−27, +27]. Red attacks `+X` and defends `−42`; blue mirrors it. **Ends are
not swapped at half-time**, so every recorded coordinate means one thing for
the whole replay.

| thing | value |
|---|---|
| map scale | 1 map pixel = 75 000 µm (0.075 m) |
| board | 1200 × 800 map px → 90 m × 60 m including the 3 m surround |
| playing surface | x ∈ [3 m, 87 m], y ∈ [3 m, 57 m] — **84 m × 54 m** |
| centre spot / circle | (45 m, 30 m), r = 9 m |
| goal mouths | the planes x = 3 m and x = 87 m, y ∈ [26 m, 34 m] — 8 m wide |
| goal netting | 2.4 m deep behind each mouth |
| goalposts | static circles, r = 0.1 m, at the four mouth corners |
| penalty areas | x ≤ 19 m / x ≥ 71 m, \|y − 30 m\| ≤ 20 m — 16 m × 40 m |
| six-yard boxes | x ≤ 8.5 m / x ≥ 81.5 m, \|y − 30 m\| ≤ 10 m |
| surround | the 3 m band outside the pitch; cogs may stand in it |
| cog radius / ball radius | 0.5 m / 0.22 m |
| neutral drop spots | (±21 m, ±13.5 m) in view coordinates |

## Time

24 ticks per second. A match is **5760 ticks = 240 s = 4:00**, played as **two
halves of 2880 ticks**, divided into **24 decision turns of 240 ticks (10.0 s)**
— twelve per half. Each tick integrates **four substeps** of 1/96 s, so the
fastest ball (32 m/s) moves 0.33 m per substep, less than its 0.44 m diameter,
and cannot tunnel through a cog or a post.

## The nineteen actions

A cog's action for one tick is exactly **one `uint8`** — the same byte the
replay records and the wasm viewer replays.

| bits | field | values |
|---|---|---|
| 0–3 (`b and 0x0F`) | direction | `0` = none (release_direction / idle), `1..8` = N, NE, E, SE, S, SW, W, NW (screen convention, y down). `9..15` are illegal → read as `0`. |
| 4–6 (`(b shr 4) and 0x07`) | one-shot action | `0` none, `1` short_pass, `2` long_pass, `3` high_pass, `4` shot, `5` slide, `6` dribble_on, `7` dribble_off |
| 7 (`b and 0x80`) | sprint | set = sprint held; clear = release_sprint |

That is gfootball's nineteen actions exactly. `sprint` and `dribble` are
**sticky modes**; the rest are one-shot and cleared after resolution. A pass or
shot code from a cog that does not control the ball is recorded and ignored.

## Bodies

- **Cog movement.** Target velocity = the direction unit vector × the mode
  speed; velocity moves toward it by at most `Accel = 25 000` µm/tick² per
  tick, and decays by `v -= v·96/1024` when the direction is `0`. Mode speeds:
  base **250 000** µm/tick (6.0 m/s), sprint **337 500** (8.1 m/s), dribble
  **200 000** (4.8 m/s), keeper base **229 000** (5.5 m/s).
- **Stamina.** 0..1000, starts 1000, −6 per sprinting tick, +2 otherwise. Below
  200 every mode speed is ×85 %; below 50 the sprint bit is ignored. Stamina is
  in `gameHash`.
- **Ball on the ground.** `v -= v·7/1024` per tick, capped at 32 m/s.
- **Ball in the air** (high pass only). `z` follows an integer parabola with a
  4 m apex; gravity is 4 340 µm/tick². An airborne ball ignores cogs until
  `z ≤ 0.4 m`.
- **Passes.** Short: ground, 14 m/s, max range 25 m. Long: ground, 22 m/s, max
  45 m. High: airborne, 18 m/s, max 40 m. The receiver is the teammate with the
  best `passScore` inside a ±50° cone about the passer's **direction bits**;
  `passScore = openness_mm − 2 × distance_to_own_goal_mm`. The ball is aimed at
  the receiver's position + its velocity × 12 ticks.
- **Shots.** 26 m/s, aimed at the goal-mouth point furthest from the keeper.
  Aim error in brads is `rng.rand(2·E) − E` with `E = 2 + dist_m/6 + (4 if an
  opponent is within 2 m)`, drawn from the seeded sim RNG.
- **Control and interception.** After ball motion, the cog nearest the ball
  within 1.1 m takes possession **iff** the ball's ground speed ≤ **18 m/s** and
  it is not grounded or sliding; ties by ascending cog index. Eighteen, not the
  design note's twelve: twelve is below the 14 m/s short pass, so no pass could
  ever be received on arrival and a whole certification episode finished 0–0
  with one shot, every pass ricocheting off its receiver. Eighteen draws the
  line where football draws it — you can control a pass, you cannot control a
  shot (26 m/s) or a long ball at full pace (22 m/s). A faster ball
  deflects off the cog with restitution 45 %. A cog in possession carries the
  ball 0.9 m ahead of its velocity (0.55 m with dribble mode on).
- **Slide tackle.** A 12-tick slide at 400 000 µm/tick along the held
  direction; the collision radius grows to 0.9 m and the direction cannot
  change. Reaching the ball first knocks it loose (`tackle`). Reaching an
  **opponent** without having touched the ball on any tick of the slide is a
  **foul**: the tackler is grounded for 48 ticks and the opponent gets an
  indirect free kick. After any slide the cog is grounded for 24 ticks. There
  are no cards and no penalties — a foul in the penalty area is a free kick on
  the 16 m line.
- **Keeper.** Shirt 1, always built-in AI. Inside its own penalty area it
  **catches** a ball within 1.5 m at ≤ 18 m/s → dead ball, `save`, goal-kick
  restart. A faster ball is **parried**: reflected with restitution 60 % and
  capped at 12 m/s. Outside its area the keeper is an ordinary cog.
- **Cog–cog contact.** Circle separation, each pushed half the penetration,
  normal impulse with restitution 20 %. No fouls arise from this.
- **Boundaries.** A cog's centre is clamped inside the board box; cogs never
  leave the board. Only the ball goes out of play.

## Out of play and restarts

The ball is **out** when its centre crosses a pitch edge; goal-mouth crossings
are tested first.

| trigger | restart | taker | spot |
|---|---|---|---|
| over a touchline | **throw-in** to the team that did *not* touch it last | nearest teammate | the crossing point |
| over a goal line, last touched by an **attacker** | **goal kick** | the defending keeper | the six-yard box corner nearest the crossing |
| over a goal line, last touched by a **defender** | **corner** | nearest attacking teammate | the corner arc |
| inside a goal mouth | **goal** → kickoff by the conceding team | that team's shirt 10 | centre spot |
| keeper catch | goal kick | the keeper | six-yard box centre |
| foul | **free kick** to the fouled team | nearest teammate | contact point, pushed out of the penalty area |
| half-time / match start | **kickoff** | shirt 10 of the kicking team | centre spot |

Every restart is a **dead-ball phase** of `restartTicks = 36` (1.5 s): the ball
sits on the spot and cannot be touched, the taker is snapped 0.8 m behind it,
every opponent inside 5 m is pushed radially out to exactly 5 m, and all other
cogs move normally under their own control. On the last tick the ball becomes
live with the taker in possession. There is **no offside** in v1 and no
advantage rule.

**Stalemate guard (sim-level, so no policy can defeat it).** If the ball's
centre stays inside a 2 m box for **480 ticks (20 s)** with no possession
change, the referee drops the ball at the nearest of the four neutral spots,
pushes every cog within 5 m out to 5 m, and fires a `drop`. It is inside
`gameHash`, so it is part of the recorded truth.

## Resolution order

Every tick `t`, in this exact order, no exceptions:

1. **Turn boundary.** If `t mod 240 == 0` each seat's collected order becomes
   its active directive and one `directive` record per seat is written.
   Directives are **excluded from `gameHash`**: nothing a seat says can move
   the hash chain, only the action bytes it produces can.
2. **Timers** decrement: `slideTicks`, `groundedTicks`, `passCooldown` (12),
   `shotCooldown` (18); globally `restartTicks` and the stalemate counter.
3. **Control compile.** For each cog in index order `RED-1..11`, `BLUE-1..11`,
   the deterministic control layer emits one `uint8`. Unseated shirts get the
   built-in AI's byte. During a restart the taker's byte is forced to `0x00`
   and every other cog's action code is forced to `0`.
4. **Record.** The 22 bytes go to the sim and to the replay. **This is the
   determinism boundary.**
5. **Modes.** The sprint bit, the dribble toggles, stamina, and slide starts.
6. **On-ball actions**, for the cog in possession only: `1/2/3` release a pass,
   `4` a shot; possession clears.
7. **Four substeps**, each: cog integration → ball integration → cog–cog →
   cog boundary clamp → slide volumes → ball vs cogs → carry → ball vs posts →
   netting → goal test → out-of-play test.
8. **Possession bookkeeping**, touches, passes, interceptions, shots, tackles.
9. **Stalemate counter** and, at 480, the neutral drop.
10. **Hash.** One `gameHash` per tick.
11. **Boundaries.** Half-time at 2880; `turn_end` and mercy at a goal
    difference of 5 on a turn boundary; full time at `maxTicks`.

## Scoring

Team zero-sum and margin-sensitive; every seat on a team gets its team's score:

```
gd(team)    = goals[team] − goals[other]
score(seat) = 0.5 + 0.5 · clamp(gd(team of seat) / 3, −1, +1)
```

**Higher is better.** 3–0 or better = 1.000; 2–0 = 0.833; 1–0 = 0.667; any draw
= 0.500. The eight `scores` sum to exactly **4.000** in every legal outcome and
the two team scores sum to 1.000. `win[seat] = gd(team) > 0`. A `fault` episode
scores 0.500 × 8 with `win` all false — an infra fault is nobody's loss.

Per-seat football statistics (goals, assists, passes, tackles) are reported for
the board and the feed but are **not** in the score: checkpoint shaping is
deliberately off in v1, because a shaped individual reward is exactly what
makes a team zero-sum game collusion-friendly.

## End conditions

| `reason` | `endRule` | when |
|---|---|---|
| `complete` | `full_time` | 5760 ticks played. The normal ending. |
| `complete` | `mercy` | goal difference ≥ 5 at a turn boundary. |
| `deadline` | `wall_clock` | `wallClockBudgetSeconds` (690) elapsed first. The score at that instant stands and the replay is complete up to the stop tick. |
| `fault` | `sim_fault` | a physics invariant guard tripped. 0.500 × 8. |
| `fault` | `host_error` | an unexpected server-side exception. 0.500 × 8. |

### Disconnects

A seat that never connects does **not** end the episode. After
`lobbyJoinTimeoutTicks` (1440 = 60 s) the no-show is reported to
`COGAME_PLAYER_FAILURE_URI`, its shirt is driven by the `zonal` baseline for the
whole match, and the match plays to full time. A seat that drops mid-match keeps
playing the same way and revives on reconnect. **No failure mode leaves a cog
unactuated.**

## Determinism

Replays are re-simulated by the **emscripten/wasm32** build of the same Nim
module the **native amd64** server ran, and their per-tick `gameHash` chain must
match exactly. That is true by construction, not by argument:

* every stored sim field is an explicit `int32` / `bool` / enum — never a bare
  `int`, which is 64-bit natively and 32-bit under `--cpu:wasm32`;
* every product or quotient of two sim quantities is taken in `int64` and
  narrowed with an explicit truncating `div` (Nim's `div` truncates toward zero,
  so the arithmetic is symmetric under negation — which is what makes the two
  ends of the pitch exactly fair);
* there is **no floating point** in
  `src/grf_football/{sim,sim_types,sim_config,sim_state,pitch,control,builtin_ai,trig}.nim`,
  grep-enforced by `tests/test_determinism.nim`;
* trigonometry is a committed literal table (`SinQ12`), the only square root is
  `isqrt`, and the only atan2 is `bradsOfVectorI`;
* the only randomness is the seeded sim RNG, used for exactly two things: the
  kickoff Y jitter and the shot aim error;
* a directive's `pass_to` is NOT readable in the sim — a directive is not in the
  action log — so the receiver is always chosen from the recorded action byte's
  direction nibble, and the control layer is what points those bits at the
  named teammate.

CI proves the cross-build equality on every push: the `wasm-viewer` job runs
`node tools/wasm_replay_smoke.cjs dist/static-replay-viewer <fixture> 300`,
which fails if `grf_mismatch_tick() != -1`.

## Out of scope (v1)

The academy drills (empty goal, run-to-score, 3v1 with keeper, pass-and-shoot,
corner, counterattack); checkpoint or any individual reward shaping; offside,
cards, penalties, advantage, injury time and substitutions; ends swapped at
half-time; any camera that is not the fixed whole-pitch view; seats commanding
more than one shirt, and seat counts other than 8; any 3D or broadcast-camera
rendering; raw per-tick action control by an external policy.
