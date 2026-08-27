# grf-football

**Eleven-a-side association football in a continuous 2D physics world.**
Twenty-two wheeled cogs and one ball on an 84 m × 54 m pitch; the ball goes out
(throw-ins, corners, goal kicks); goals win the match. It reimplements the
*spirit* of Google Research Football — 11 v 11, a nineteen-action discrete
vocabulary, and unseated players run by the engine's built-in AI — as a new
physics game written for this coworld.

**A policy is just a prompt.** A seat does not drive a joystick. Every ten
seconds of match time it issues ONE order for its shirt — a role, an intent, a
target point, an on-ball choice, sprint and tackle permissions — and a
deterministic control layer executes it for the next ten seconds. Twenty-four
turns, one order each.

```
                             +27 m
   RED     ┌───────────────────────────────────┐     BLUE
   goal  ▐│  RED-6      RED-10   (o)  BLUE-9   │▌   goal
         ▐│      RED-7        BLUE-6     BLUE-7│▌
          └───────────────────────────────────┘
                             −27 m
```

* [docs/RULES.md](docs/RULES.md) — the pitch, the physics, the nineteen
  actions, the restart table, the scoring and the determinism contract.
* [docs/PROTOCOL.md](docs/PROTOCOL.md) — the runtime contract, the seat
  protocol, the `COWLDFTB` replay bytes and the results document.
* [docs/COACHING.md](docs/COACHING.md) — how to write a grf-football prompt.

## Seats and scoring

`num_agents` is **8**: four seats a side, one outfield shirt each (`RED-10`,
`RED-9`, `RED-7`, `RED-6` and the blue mirror). The other seven shirts a side,
keeper included, are the built-in AI. Team zero-sum and margin-sensitive:

```
score(seat) = 0.5 + 0.5 · clamp((goals_you − goals_them) / 3, −1, +1)
```

3–0 or better = 1.000; 1–0 = 0.667; any draw = 0.500. Higher is better; the
eight scores always sum to 4.000.

## Playing

One image, two entrypoints, every policy env-switched:

```bash
# the game
docker run --rm -e COGAME_CONFIG_URI=file:///coworld/config.json \
  coworld-grf-football:latest /bin/grf-football

# an LLM seat
docker run --rm -e COWORLD_PLAYER_WS_URL=ws://game:8080/player?slot=0 \
  -e PLAYER_PROMPT="Play possession football and make the pitch big…" \
  coworld-grf-football:latest /bin/grf-football-player

# a scripted seat
docker run --rm -e COWORLD_PLAYER_WS_URL=ws://game:8080/player?slot=1 \
  -e PLAYER_SCRIPTED=zonal \
  coworld-grf-football:latest /bin/grf-football-player
```

`zonal` is the reference baseline (hold the zone, support the ball, press when
it is close) and also the fallback whenever a decision call fails twice.
`gegenpress` is the second filler — press everywhere, sprint always — which
fades on stamina around the third minute, so the ladder has a spread.

## Watching

The replay ships as a **static wasm bundle**, never a pod:
`tools/build_replay_viewer.sh` builds `replay-viewer/grf_football_replay.nim` —
which imports the **same** `src/grf_football/sim.nim` the native server ran —
through the pinned `emscripten/emsdk:4.0.15` container, and the browser
re-simulates the recorded action log and checks the recorded `gameHash` every
tick.

The broadcast chrome shows: the score bug (goals, shots on target, possession),
the clock with the half and turn, a plain-language match feed carrying the
seats' own notes and shouts, a ball trail tinted by the last toucher with a
shadow while the ball is airborne, pass arcs and shot streaks, a goal
celebration, an **instant slow-mo goal replay**, a possession bar, and the
seated-shirt rings that say at a glance which four cogs a side are being played
by a policy.

## Layout

```
src/grf_football.nim           game entrypoint (seed randomisation lives here)
src/grf_football_player.nim    every policy: registers, then idles
src/grf_football/
  sim_types.nim                consts (incl. GameVersion), types, the action byte
  trig.nim                     the committed SinQ12 table, isqrt, bradsOfVectorI
  pitch.nim                    geometry, the out tests, the restart spots
  sim.nim                      the integer physics core and the step loop
  builtin_ai.nim               the fourteen unseated shirts and the safe option
  control.nim                  order -> 22 action bytes (integer only)
  directives.nim               view coordinates, rune truncation, the parser
  baselines.nim                the zonal and gegenpress scripted policies
  llm.nim                      the credential ladder and transport
  decide.nim                   the turn engine: ONE parallel batch of eight
  server.nim                   mummy HTTP/ws, the COGAME_* contract, the loop
  replays.nim                  the COWLDFTB codec, keyframes, the scan
  global.nim                   the board renderer
  broadcast.nim                the chrome JSON channel and the record fold-back
  rig_art.nim                  the wheeled-rig compositor and the shirt chips
replay-viewer/                 the emscripten entry point and the worker
client/                        the broadcast chrome (kept from coworld-ctf)
tools/                         build hooks, forensics, CI helpers
tests/                         the determinism gate and thirteen suites around it
```

## Building and testing

The repo builds with [nimby](https://github.com/treeform/nimby):

```bash
nimby --global sync nimby.lock
nim r --path:src tests/test_determinism.nim
```

CI runs every `tests/*.nim` twice — debug (range and overflow checks) and
`-d:release` — plus a raw-Docker episode smoke and the wasm bundle build with
the native↔wasm determinism gate. See `.github/workflows/ci.yml`.

Design notes live in `docs/plans/`. The lineage is
[`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf) (paintbot):
the game loop, the per-tick replays, the static wasm viewer, the broadcast
chrome and the CI wiring are its, kept; the football rules replace the arena
rules.
