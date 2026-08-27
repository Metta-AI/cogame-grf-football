## Sprite-label vocabulary: the machine-readable CONTRACT between the engine
## (the producer, `global.nim`) and anything reading the wire — the seat
## streams, the inspector, the sprite-dedup audit.
##
## A label is not a debug tag: it is the observation schema. Labels are
## computed at render time and never serialized (flatty writes `SimServer`
## positionally, so replays carry no label bytes) and nothing type-checks a
## label string, so renaming one is silent. Hoisting the strings to consts
## makes producer and consumer share one definition.
##
## **This module must keep ZERO imports.** Kept from ctf verbatim in spirit.

const
  LabelPitch* = "pitch"
    ## One horizontal band of the baked turf. The board is banded so no single
    ## websocket frame exceeds the hosted replay's 1 MiB ceiling.
  LabelBall* = "ball"
    ## The match ball. Its object position IS the ball's map-pixel centre.
  LabelBallShadow* = "ball shadow"
    ## The drop shadow under an airborne ball; a high pass visibly leaves the
    ## ground because the shadow stays on the turf while the ball rises.
  LabelCog* = "cog"
    ## A footballer of either side. The full label is `cog <id>`, e.g.
    ## `cog RED-9` — the anonymous in-game identity, never a policy name.
  LabelShirtChip* = "shirt number"
    ## The baked shirt-number chip over a cog.
  LabelSeatRing* = "seat ring"
    ## The bright ring marking one of the eight POLICY-DRIVEN shirts, so a
    ## spectator can see at a glance which four cogs a side are being played.
  LabelSelfMarker* = "own cog"
    ## Marks the receiving seat's own shirt. Player streams only.
  LabelOwnSeat* = "own seat"
    ## An invisible 1x1 marker naming the receiving seat's shirt alias
    ## (`own seat RED-9`). Player streams only; it is how a seat learns which
    ## shirt is its own without ever seeing a real player name.
  LabelBallTrail* = "ball trail"
    ## One tapering segment of the last 40 ticks of ball positions, tinted by
    ## the last toucher's livery.
  LabelArc* = "play arc"
    ## A pass arc, a shot streak, or a save/post burst.
  LabelGoalFlash* = "goal flash"
    ## The full-canvas flash on a goal.
  LabelConfetti* = "goal confetti"
    ## One celebration particle in the scoring livery.
  LabelChrome* = "broadcast chrome"
    ## The reserved never-drawn 1x1 sprite whose LABEL carries the broadcast
    ## chrome JSON. It rides the binary sprite channel because that is the only
    ## channel that survives a hosted replay.

  ContractLabels*: array[12, string] = [
    LabelPitch, LabelBall, LabelBallShadow, LabelCog, LabelShirtChip,
    LabelSeatRing, LabelSelfMarker, LabelOwnSeat, LabelBallTrail, LabelArc,
    LabelGoalFlash, LabelConfetti
  ]
    ## The golden vocabulary, minus the chrome carrier. `tests/test_viewer.nim`
    ## asserts the renderer emits nothing outside it.
