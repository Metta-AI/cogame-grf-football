# Writing a grf-football prompt

A grf-football policy is a **prompt**. You do not drive a joystick, and you do
not write code: you play one shirt. Every ten seconds of match time the game
server sends your prompt, plus your shirt's view of the pitch, to Claude and
asks for one JSON order. A deterministic control layer then executes that order
for the next ten seconds — steering, sprinting, tackling and playing the ball.

Twenty-four turns, one order each. That is the whole game from your side.

## What you control, and what you do not

`num_agents` is **8**: four seats a side, one shirt each.

| seat | shirt | role |
|---|---|---|
| 0 / 1 | `RED-10` / `BLUE-10` | playmaker |
| 2 / 3 | `RED-9` / `BLUE-9` | striker |
| 4 / 5 | `RED-7` / `BLUE-7` | winger |
| 6 / 7 | `RED-6` / `BLUE-6` | anchor |

The other **seven shirts on your side, including the keeper, are the engine's
built-in AI**. It holds a 4-3-3 shape, tackles when the ball is at its feet,
passes to the nearest better-placed teammate and never carries the ball more
than 8 m. It also **yields to you**: when a seated cog and a built-in cog of the
same team are both within 3 m of a loose ball, the built-in cog steps off and
takes a support point instead. Three other shirts on your team are played by
policies you cannot talk to.

## The order

```json
{"note": "sitting on their last man",
 "cogs": [{"id": "RED-9", "role": "striker", "intent": "make_run",
           "target": [24.0, -6.0], "on_ball": "shoot", "pass_to": "RED-10",
           "sprint": "auto", "tackle": "auto", "say": "in behind"}]}
```

Exactly one entry, for the shirt you control. Everything is in **view
coordinates**: metres from the centre spot, x ∈ [−42, 42], y ∈ [−27, 27]. Your
own goal and the one you attack are named for you every turn in
`you.attacking_goal` / `you.defending_goal`, so a prompt never has to remember
which side it is on.

## What each intent actually does

The control layer is the same code for every policy, so two prompts are
strictly comparable.

| intent | your shirt… |
|---|---|
| `press` | closes down whoever has the ball (lead 8 ticks); chases the interception point if the ball is loose |
| `hold_shape` | holds `target`, blended halfway with your formation anchor |
| `make_run` | runs 12 m ahead of the ball on your side, at your `target`'s y |
| `support` | offers a short option 9 m beside the ball, on the own-goal side |
| `drop_deep` | comes back to the midpoint of the ball and your own goal |
| `carry` | goes and gets the ball and runs at their goal |
| `switch_play` | moves to the far side of the pitch, 18 m off centre |
| `shadow` | marks the nearest opponent (lead 12 ticks) |

`target` is used **directly** by `hold_shape` and as a **25 % bias** by
everything else, so it is a useful nudge even on `press`.

**One override outranks every intent.** If the ball is loose and you are the
closest of your team to it, you go and win it. A footballer who can win the
ball, wins it — no prompt can talk you out of that.

## on_ball

`on_ball` is what you do when the ball is at YOUR feet. An illegal choice is
ignored and the controller plays the **safe option** (the built-in AI's on-ball
rule) instead:

| on_ball | when it is legal |
|---|---|
| `shoot` | inside 30 m of their goal with no teammate in the shooting lane |
| `pass_short` | a legal receiver inside 25 m |
| `pass_long` | a legal receiver inside 45 m |
| `pass_high` | a legal receiver inside 40 m; the ball leaves the ground |
| `dribble` | always; turns dribble mode on and runs at the goal |
| `hold` | always; shields the ball away from the nearest opponent |

`pass_to` names a **teammate** shirt — any of the eleven, seated or built-in.
It is a preference, not a command: if that shirt is out of range the controller
picks the best `passScore` receiver instead. (Mechanically, the controller
points your direction bits at the chosen receiver and the sim resolves the pass
inside a ±50° cone about them; that is why the pass is reproducible from the
recorded action byte alone.)

## Stamina is real

`sprint: "always"` drains 6 stamina a tick and recovers 2. Below 200 you run at
85 % **for the rest of the match**; below 50 the sprint bit is ignored
altogether. `gegenpress`, the second scripted filler, sprints always and fades
around the third minute — that is exactly why it loses to `zonal`.

## Fouls are real

A slide tackle that reaches the ball first wins it. One that reaches the
opponent first without having touched the ball is a **foul**: you lie grounded
for two seconds and they get a free kick. `tackle: "never"` turns your slides
off entirely — worth it for the last defender.

## What actually wins

Things that show up in the replays:

* **Move when your team has the ball.** A shirt standing still is a shirt the
  built-in AI cannot pass to. `support` with a target 8–12 m to the side of the
  ball keeps a short option on at all times.
* **Do not press with everybody.** Only the closest shirt should `press`; the
  other three holding shape is what stops a counter.
* **Shoot from inside 20 m.** The aim error grows with distance (`2 + dist/6`
  brads) and a shot from 40 m is a goal kick.
* **Watch `your_cog.stamina`.** If it is under 300 at turn 12, you set sprint
  to `always` too early.
* **Use `note` and `say`.** They are what a spectator reads in the match feed —
  this is where your policy visibly plays football rather than merely scoring.

## Two worked prompts

The two shipped champions, `grf-football-tiki` (possession) and
`grf-football-counter` (counter-attack), are in `tools/ci/policies.json`. They
are deliberately different in shape: one keeps the ball and makes the pitch
big, the other sits deep and hits the space behind. Read them, then write a
third.
