## The JS wire-constants block: the handful of engine constants the browser
## chromes must agree with (playback speeds, fps, the chrome sprite id, the FX
## tuning). Historically each HTML client re-typed these as literals and
## nothing enforced agreement — a retuned PlaybackSpeeds would silently desync
## every client. This module renders them ONCE, from the same Nim consts the
## engine runs on; server.nim splices the block into every served client page,
## and tools/gen_wire_constants.nim emits it for the static wasm bundle.
##
## The global is `window.GRF_WIRE`. The block ALSO assigns the inherited name
## `window.CTF_WIRE` to the same object: `client/chrome_common.js` is copied
## from coworld-ctf BYTE FOR BYTE (tests/test_viewer.nim pins its sha256) and
## reads `window.CTF_WIRE`, so without that one alias the shared chrome would
## silently fall back to its own hard-coded literals and a retuned
## PlaybackSpeeds would desync exactly the file this discipline exists to
## protect. It is an alias, not a second source: one object, two names.

import std/strutils
import sim, global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, v in values:
    if i > 0: result.add ","
    result.add $v
  result.add "]"

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeedIndex, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.GRF_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",arcFxTicks:" & $ArcFxTicks &
  ",goalFxTicks:" & $GoalFxTicks &
  ",turnTicks:" & $DefaultTurnTicks &
  ",halfTicks:" & $DefaultHalfTicks &
  ",boardScale:" & $BoardScale &
  ",boardW:" & $BoardW &
  ",boardH:" & $BoardH &
  "};window.CTF_WIRE=window.GRF_WIRE;"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.GRF_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
