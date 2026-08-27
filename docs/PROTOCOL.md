# grf-football — wire protocol

Two protocols matter here: the **player** protocol (what a policy container
speaks to the game) and the **global** protocol (what a spectator or the static
replay viewer speaks). Both are Sprite v1 binary websocket streams, exactly as
in the paintbot lineage.

## Runtime contract

The game container reads and writes the standard `COGAME_*` URIs:

| variable | meaning |
|---|---|
| `COGAME_CONFIG_URI` | the episode config JSON (read at startup) |
| `COGAME_RESULTS_URI` | the results document (written once, at game over) |
| `COGAME_SAVE_REPLAY_URI` | the `COWLDFTB` replay bytes |
| `COGAME_LOAD_REPLAY_URI` | a replay to serve instead of playing a match |
| `COGAME_PLAYER_FAILURE_URI` | `{"failed_policy_index": N, "message": "…"}` |
| `COGAME_EVENTS_URI` | the tier-2 JSON-lines analysis stream (`file://` only) |
| `COGAME_HOST` / `COGAME_PORT` | the bind address (default `0.0.0.0:8080`) |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_API_KEY_URI` | the decision credential |

## Routes

| route | method | purpose |
|---|---|---|
| `/healthz` | GET | liveness; returns `healthy` |
| `/player?slot=N&token=T` | GET (ws) | one seat's stream |
| `/global` | GET (ws) | the spectator board |
| `/replay` | GET (ws) | the replay board (replay mode) |
| `/client/global`, `/client/player` | GET | the bitworld generic clients |
| `/client/replay` | GET | the designed broadcast client, **live pod only** |
| `/client/font.ttf` | GET | the chrome font |
| `/replay-data` | GET | the current replay bytes |

**The hosted replay viewer is never one of these routes.** It is the STATIC
wasm bundle: `coworld_manifest_template.json` declares
`"replay_viewer": {"bundle": "static-replay-viewer"}`,
`.github/workflows/coworld-release.yml` hard-fails certification if the
certifier reports anything else, and the bundle re-simulates in the browser and
fetches nothing but the S3 replay object. The `/client/*` pages exist for a
**locally running game pod** — `docker run` plus a browser.

A bad slot or a token that does not match the configured slot is refused with
**403 before the websocket upgrade**. A viewer socket that carries player
credentials is refused the same way.

## The player protocol

### Registration — the only thing a seat ever sends that matters

On connect, a seat sends **one Sprite v1 chat message** (`0x81`, u16 length,
then the raw payload) carrying:

```json
{"type":"register",
 "prompt":"<strategy text or empty>",
 "scripted":"zonal"|"gegenpress"|null,
 "policy":"<free label>"}
```

* A non-empty `prompt` makes the seat an **LLM seat**: the game server sends
  that text to Claude once per decision turn.
* Otherwise `scripted` selects a built-in baseline; an unknown or absent value
  is `zonal`.
* `policy` is a free label, capped at **48 runes**, recorded in the replay.
* `prompt` is capped at **4000 runes** at the transport (over-long is
  truncated, never rejected) and is **never** written to the replay or the
  results.

The payload is read WITHOUT an ASCII filter, so a non-ASCII policy label
survives to the replay intact. Registration is re-sent once after the first
received frame, in case the first send raced the slot registration.

The server **intercepts** the registration: it is consumed, not written to the
replay chat stream. A redacted `register` record is written instead. **Any
other chat text from a player is dropped.**

### Frames

Each seat's websocket receives one binary Sprite v1 message per tick.

**Visible:** the whole pitch and all 22 cogs — football is a perfect-information
sport, so there is no fog of war; the ball; the score; the clock, half and turn;
the restart phase; a self marker on its own shirt; and an invisible
`own seat <alias>` marker naming it.

**Hidden:** every other seat's directive, prompt, note, `say` and view; the
episode seed; the built-in AI's internal target points; **real policy names**
(board labels carry only `RED-9`-style aliases); and every future tick.

A seat sends **no inputs** — the server computes every action byte — so the
Sprite v1 Ready packet (`0x85`) is legitimate after each received frame and is
what lets `fastMode` pace the match by readiness.

## The per-seat view given to the LLM

View coordinates (metres, centred), rounded to one decimal.

```json
{"turn": 7, "of": 24, "half": 1,
 "clock": {"played_s": 70.0, "left_s": 170.0},
 "score": {"you": 1, "them": 0},
 "you": {"id": "RED-9", "role": "striker", "team": "RED",
         "attacking_goal": [42.0, 0.0], "defending_goal": [-42.0, 0.0]},
 "pitch": {"x_min": -42, "x_max": 42, "y_min": -27, "y_max": 27,
           "goal_half_width": 4.0, "your_penalty_area": "x <= -26, |y| <= 20",
           "offside": false},
 "phase": "playing" | "throw_in" | "corner" | "goal_kick" | "free_kick" | "kickoff",
 "restart": {"kind": "corner", "team": "RED", "taker": "RED-7", "ticks_left": 24},
 "ball": {"pos": [3.2, -1.0], "vel": [4.1, 0.6], "speed": 4.2, "height": 0.0,
          "controller": "BLUE-4", "in_your_half": false},
 "your_cog": {"id": "RED-9", "pos": [6.1, -2.4], "vel": [2.0, -0.4],
              "speed": 2.0, "stamina": 780, "sprinting": false,
              "dribbling": false, "grounded": false, "dist_to_ball": 3.4,
              "has_ball": false,
              "nearest_opponent": {"id": "BLUE-5", "dist": 2.1}},
 "your_team": [{"id": "RED-10", "pos": [-1.2, 4.0], "role": "playmaker",
                "driver": "seat", "dist_to_ball": 5.5}, "… 11 …"],
 "their_team": [{"id": "BLUE-4", "pos": [4.0, -1.0], "dist_to_ball": 1.1,
                 "has_ball": true}, "… 11 …"],
 "last_turn": {"your_passes": 3, "your_passes_completed": 2, "your_shots": 1,
               "your_tackles": 0, "team_possession_pct": 58,
               "goals": [{"tick": 1440, "by": "RED-9", "for": "you"}]},
 "your_last_directive": "… your seat's note last turn, or null on turn 0 …"}
```

## Reply schema and per-field caps

```json
{"note": "sitting on their last man",
 "cogs": [{"id": "RED-9", "role": "striker", "intent": "make_run",
           "target": [24.0, -6.0], "on_ball": "shoot", "pass_to": "RED-10",
           "sprint": "auto", "tackle": "auto", "say": "in behind"}]}
```

| field | cap / legal values | repair |
|---|---|---|
| `note` | ≤ 160 runes | truncated on a rune boundary |
| `cogs` | exactly 1 entry, the seat's shirt | extras dropped; a missing entry is filled from last turn's directive, else from `zonal` |
| `cogs[].id` | the seat's own shirt alias, case-insensitive, ≤ 8 runes | an unmatched id is assigned to the seat's shirt by position |
| `cogs[].role` | `striker` `winger` `playmaker` `anchor` | → the shirt's table role |
| `cogs[].intent` | `press` `hold_shape` `make_run` `support` `drop_deep` `carry` `switch_play` `shadow` | → `support` |
| `cogs[].target` | `[x, y]` metres | clamped to x ∈ [−42, 42], y ∈ [−27, 27]; non-finite/missing → the cog's current position |
| `cogs[].on_ball` | `shoot` `pass_short` `pass_long` `pass_high` `dribble` `hold` | → `pass_short` |
| `cogs[].pass_to` | a *teammate* shirt id ≠ self | → `null` (the controller picks the best `passScore` receiver) |
| `cogs[].sprint` | `auto` `always` `never` | → `auto` |
| `cogs[].tackle` | `auto` `never` | → `auto` |
| `cogs[].say` | ≤ 48 runes | truncated on a rune boundary |

Three further caps on strings that reach the replay: `register.policy` ≤ 48
runes, any recorded error text (`fallback.detail`) ≤ 200 runes, and the whole
serialized `directive` record ≤ 900 runes.

**Truncation is on rune (Unicode codepoint) boundaries, never bytes.** Slicing
a string by byte index on any path to the replay is forbidden: a byte-truncated
multi-byte character renders fine in a browser and then fails a strict UTF-8
parser.

**Parsing is tolerant:** markdown fences are stripped, the outermost balanced
`{…}` is taken if the model prefixed prose, `cogs` is accepted as a bare object
or as an object keyed by id, and numeric strings in `target` are accepted. Only
when no object with a usable entry can be recovered do the retry and then the
fallback fire.

## The replay bytes

The replay is the starter's **binary `COWLDFTB`** format — the same format the
static wasm viewer parses. Everything the viewer needs is in the bytes; no
server is contacted except S3 for the file.

| content | carries |
|---|---|
| header | magic `COWLDFTB`, format version, game name `grf-football`, game version `1` |
| config JSON | seed, `num_agents`, `maxTicks`, `halfTicks`, `turnTicks`, every pitch and physics constant, `players[].name`, `slots[].team`, `fastMode` |
| joins | per seat: name, slot, token |
| inputs | per **cog** (0..21), on change: the `uint8` action byte — the action log |
| chats | the `register` / `directive` / `fallback` / `budget_guard` / `result` records |
| hashes | one `gameHash` per tick — the integrity chain the viewer checks |

Action bytes are indexed by **cog**, not by roster slot, and a player leaving
does **not** shift the arrays: the 22 cogs are fixed for the whole match.

### Record vocabulary

| `k` | fields |
|---|---|
| `register` | `seat`, `team`, `shirt`, `id`, `policy` (≤48 runes), `kind` (`llm`\|`scripted`), `baseline` |
| `directive` | `turn`, `half`, `seat`, `id`, `team`, `source` (`llm`\|`scripted`\|`fallback`), `latency_ms`, `note`, `cogs`:[{`id`,`role`,`intent`,`target`,`on_ball`,`pass_to`,`sprint`,`tackle`,`say`}] |
| `fallback` | `turn`, `seat`, `attempt` (1\|2), `cause`, `detail` (≤200 runes) |
| `budget_guard` | `turn`, `remaining_s` |
| `result` | the full results document, written once at game over |

Every record is capped at **900 runes**, on a rune boundary, and an over-long
record is shrunk STRUCTURALLY (its string values are clipped) so it always
stays parseable JSON.

### Reading a replay without Nim

`tools/replay_summary.py` (Python 3 standard library only — no Nim, no Docker)
prints one strict-UTF-8 JSON object describing a `.replay`:

```bash
python3 tools/replay_summary.py /tmp/ep.replay | jq .
```

```json
{"protocol":"grf-football/v1","gameVersion":"1","seed":679961,
 "names":[…],"aliases":["RED-10","BLUE-10","…"],"policyKinds":[…],
 "tickCount":5760,"directives":[…],"fallbacks":0,"results":{…}}
```

## Derived broadcast events

`stepEvents` derives these from state deltas during playback, so they cost no
replay bytes and are identical live and in replay: `phase`, `gamestart`,
`touch`, `pass`, `shot`, `save`, `goal`, `tackle`, `foul`, `restart`, `drop`,
`halftime`, `turn_end`, `gameover`. The **scrubber beats** — the subset with a
CSS rule in the appended chrome block — are `gamestart`, `goal` (red/blue),
`shot` (on target only), `save`, `foul`, `halftime` and `gameover`. `touch` is
throttled to at most one per cog per 8 ticks.

## Results document

Written to `COGAME_RESULTS_URI`. It equals the manifest's `results_schema` key
for key; that schema is `additionalProperties: false` and the certifier rejects
any unknown field.

```json
{"names": ["daveey", "daveey-1", "grf-football-zonal", "…8…"],
 "scores": [0.667, 0.333, 0.667, 0.333, 0.667, 0.333, 0.667, 0.333],
 "win": [true, false, true, false, true, false, true, false],
 "team": ["red", "blue", "red", "blue", "red", "blue", "red", "blue"],
 "shirt": [10, 10, 9, 9, 7, 7, 6, 6],
 "goals": [0, 1, 2, 0, 0, 0, 0, 0],
 "assists": [1, 0, 0, 0, 1, 0, 0, 0],
 "passes": [14, 11, 9, 8, 12, 10, 16, 15],
 "passesCompleted": [11, 7, 6, 5, 8, 6, 14, 12],
 "shots": [2, 1, 5, 2, 1, 0, 0, 0],
 "tackles": [1, 2, 0, 1, 2, 3, 5, 4],
 "fouls": [0, 0, 0, 1, 0, 0, 1, 0],
 "llmTurns": [24, 24, 24, 24, 0, 0, 0, 0],
 "fallbackTurns": [0, 0, 0, 0, 0, 0, 0, 0],
 "teamGoals": [2, 1],
 "teamShots": [11, 6],
 "teamShotsOnTarget": [5, 2],
 "teamPossessionTicks": [3100, 2660],
 "reason": "complete",
 "endRule": "full_time",
 "finalTick": 5760,
 "seed": 679961}
```

`names` are the **real policy names** (spectator side). `team` and `shirt` carry
the in-game identity. Team arrays are `[red, blue]`.
