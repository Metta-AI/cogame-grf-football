# Prompt diversity

Bank `grf-football-rules-v2` varies team control, decision cadence, pitch rules,
fouls, and stamina. Five training wordings and two evaluation-only wordings
share the exact action schema, intent definitions, and legal coordinate ranges.
The briefing correctly assigns seven teammates to built-in AI and three to other
policies. Stamina penalties last until recovery, rather than permanently.

`promptVariant` selects `canonical` (default), `plain`, `numbered`, `questions`,
`reordered`, or `mixed`. Mixed requires a nonnegative `promptSeed` and uses modulo
five independently of simulator randomness. Selection stays fixed per match.
`heldout-briefing` and `heldout-reference` are evaluation-only; training rejects them.

Native decisions, the language bridge, and teacher exports share the renderer.
The bridge carries complete orders, spectator text, wording identity, and message
hashes; its matched games verify team outcomes, private views, and exact actions.
The change does not alter the integer physics, replay layout, or player protocol.

## Export and checks

```sh
nim c -d:release --path:src -o:/tmp/football-export tools/export_posttrain.nim
/tmp/football-export /tmp/football-data 10 1 match mixed 0
```

The exporter retains `train.jsonl`, `validation.jsonl`, and `manifest.json`.
Mixed exports cycle five wordings independently within training and validation,
recording each run's selection and message hashes. Episode IDs include wording
to distinguish matched collections. Keep each `grf-football-SEED` family together
across match lengths and wordings. All eight views are frozen before directives are installed.

`tools/test_prompt_games.py BRIDGE` plays 16 complete matches across both lengths.
`tools/test_export_posttrain.py EXPORTER` checks 20 complete mixed exports.
Existing engine, hosted-request, privacy, and manifest checks cover native paths.

Compare canonical and mixed training with matched seeds, seats, opponents, and
inference settings. Measure team score, invalid replies, fallback, requests, and
completion on familiar and held-out wording. Local checks do not establish
learned robustness or live-provider performance.
