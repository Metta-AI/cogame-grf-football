# AGENTS.md — grf-football

Eleven-a-side 2D physics football, forked from
[`Metta-AI/coworld-ctf`](https://github.com/Metta-AI/coworld-ctf) (paintbot).
Read `docs/RULES.md` before changing anything under `src/grf_football/`.

## The three rules that are not negotiable

1. **The hashed core is integer-only.** No floating point, no libm, no
   `std/math` anywhere under
   `src/grf_football/{sim,sim_types,sim_config,sim_state,pitch,control,builtin_ai,trig}.nim`.
   `tests/test_determinism.nim` greps for it. The native amd64 server and the
   emscripten wasm32 viewer are two separate compilations of that same code and
   their per-tick `gameHash` chains must match bit for bit.
2. **Every recorded string is truncated on RUNE boundaries.** `clipRunes`, never
   a byte slice. A byte-truncated multi-byte character renders fine in a browser
   and then fails a strict UTF-8 parser.
3. **`SimServer` is flatty-serialized POSITIONALLY into replay keyframes.**
   Append fields, never insert or reorder, and bump `GameVersion` with a
   changelog line when the rules change.

## Where things live

| what | where |
|---|---|
| the rules, in prose | `docs/RULES.md` |
| the wire, in prose | `docs/PROTOCOL.md` |
| how to write a prompt | `docs/COACHING.md` |
| the design note this repo was built from | `docs/plans/` |
| the scripted baseline's tuning sweep | `tools/tune_baselines.nim` → `docs/tuning/` |
| the physics | `src/grf_football/sim.nim` |
| the unseated shirts | `src/grf_football/builtin_ai.nim` |
| order → action bytes | `src/grf_football/control.nim` |
| the decision turn | `src/grf_football/decide.nim` |
| the board renderer | `src/grf_football/global.nim` |
| the chrome JSON | `src/grf_football/broadcast.nim` |
| the broadcast page | `client/replay_broadcast.html` |

## The generated files

* `coworld_manifest_template.json` is **generated**: run
  `python3 tools/build_manifest.py` after editing `README.md` or any
  `docs/*.md`, because `game.docs` inlines them as text. CI runs
  `--check` and fails on drift.
* `src/grf_football/trig.nim`'s `SinQ12` table is generated once by
  `tools/gen_trig_table.nim` and checked in. `tests/test_determinism.nim`
  re-derives every entry from `math.sin`.

## The chrome

`client/chrome_common.js` is coworld-ctf's, **byte for byte** — its digest is
pinned in `tests/test_viewer.nim`. `client/replay_broadcast.html` is ctf's page
with a game block appended under a banner; every id that block introduces is
`fb-`-prefixed, and nothing it draws goes inside the transport band.

The four replay-viewer files (`config.nims`, the wasm entry, `static_replay.js`,
`static_replay_worker.js`) all come from coworld-ctf and only from it. The
emscripten link flags are non-`MODULARIZE` and are matched by the worker's
`onRuntimeInitialized` bootstrap; splicing one starter's shell onto another's
flags hangs on "Loading replay…" forever with nothing logged.

## Testing

The sandbox has no Nim, no Docker and no emsdk: `.github/workflows/ci.yml` is
the only harness. Every `tests/*.nim` runs twice, debug and `-d:release`
(`tests/test_perf.nim` is release-only, via the `NIM_TESTS_RELEASE_ONLY` repo
variable).
