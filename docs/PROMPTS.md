# Prompt diversity and private candidates

Set `promptVariant` and `promptSeed` in game configuration. The default is
`canonical`. Training wordings are `canonical`, `plain`, `numbered`, `questions`,
and `reordered`. Evaluation also accepts `heldout-briefing` and
`heldout-reference`. `mixed` requires an explicit nonnegative seed and selects
one of the five training wordings using that seed modulo five.

Selection stays fixed for the complete match and does not consume simulation
randomness. The bank is `grf-football-rules-v1`. Only the introduction varies;
roles, private views, action schema, physics, and published budgets stay fixed.
All versions correct one original rule contradiction: seven teammates run on
built-in AI, while three other teammates have policy seats. The original prompt
incorrectly said ten teammates run on built-in AI. Canonical comparisons account
for this explicit correction; they do not claim byte identity with that sentence.

## Private native evidence

Set `GRF_FOOTBALL_TRACE_DIR` to a new private directory and
`GRF_FOOTBALL_SOURCE_REVISION` to the deployed source revision. The host creates
exclusive, mode-0600 files and never publishes them to spectator artifacts:

- `manifest.json`: source revision and actual game configuration.
- `attempts.jsonl`: actual outbound request bodies without credentials, exact
  messages, transport/model, raw responses or errors, and attempt identities.
- `decisions.jsonl`: private observations, exact rendered-message hashes,
  parser resolutions, selected attempts, and installed directives.
- `execution.jsonl`: actual 22-cog action bytes and before/after hashes for each
  tick, followed by the final result.

A started attempt without a finish is incomplete evidence, not a successful
model call. Model call identifiers and log probabilities remain null when the
transport does not provide them. Normal public replay remains `COWLDFTB` and
retains its existing directive and hash records. Keep private evidence under the
same access restrictions as operator strategies.

## Candidate export and shared collection

Build `tools/export_posttrain.nim` and run from a clean, committed checkout:

```sh
./export_posttrain /private/new-candidates 10 1 match plain 0
```

The exporter streams complete scripted-zonal matches to `trajectories.jsonl`,
with paired `execution.jsonl` and source metadata. It rejects held-out training
wordings and fewer than ten matches. It emits candidates, never automatic
training labels or training/validation files. Independent review in the shared
Coworld importer owns admission. The `grf-football-SEED` family keeps replicas
across wording and match length in the same split.

Build `tools/train_bridge.nim` for shared language collection. Its arguments are
`MANIFEST [match|half]`; reset accepts `players=8`, string `seed`, wording settings,
and `split`. The newline-JSON `reset`, `teacher`, and `step` protocol drives the
real simulation through complete matches and retains full directives and notes.
All eight simultaneous directives are staged before installation. Held-out
wordings are rejected for `split=train`.

## Validation and learning comparison

```sh
python3 tools/test_prompt_games.py /absolute/path/to/train_bridge
python3 tools/test_native_prompts.py /absolute/game /absolute/player /absolute/rehash /private/new-native
```

The first command checks complete matched games, selection stability, rendered
hashes, private notes, and action/outcome invariance. The native command runs
published match lengths and budgets with real player processes and an unavailable
local inference endpoint. It checks actual retries/fallbacks, private strategies,
installed directives, action bytes, and native replay re-simulation. `--smoke`
restricts the panel to both canonical configurations without shortening either.

These checks establish plumbing and scripted behavior, not learning improvement.
Compare canonical-only training with uniform five-wording training using the same
model initialization, game seeds, optimizer settings, and decision budget. Evaluate
both checkpoints on canonical, training, and held-out wordings with paired seeds.
Report mean score, score spread across wordings, invalid-action and fallback rates,
and completed games separately from failures. Inspect worst paired regressions
and private-information exposure. Production model and learning comparisons remain
unrun; do not infer their results from deterministic or closed-endpoint tests.
