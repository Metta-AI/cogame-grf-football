## The CHROME CONTRACT. `client/chrome_common.js` is the starter's, byte for
## byte (sha256 pinned here); `client/replay_broadcast.html` is the starter's
## page with a game block appended, carrying no `#fpv`/`#viewpanel` id and
## still carrying every kept id; the appended block's new ids are all
## `fb-`-prefixed; a CSS rule exists for every emitted beat kind; and the
## `.tiny` and `.plate-name` rules are present.

import std/[os, strutils]
import lib/helpers

const
  ChromePath = "client/chrome_common.js"
  PagePath = "client/replay_broadcast.html"
  Banner = "GRF-FOOTBALL additions to the inherited coworld-ctf chrome"
  BeatKinds = ["gamestart", "goal", "shot", "save", "foul", "halftime",
               "gameover"]
  KeptIds = ["viewport", "stage", "board", "lightpool", "grain", "lockerroom",
             "chrome", "scorebug", "plates-l", "plates-r", "clock",
             "clock-time", "clock-caption", "mmwarn", "bannerlane",
             "killfeed", "transport", "scrub", "momentum", "scrub-fill",
             "lulls", "scrub-win", "scrub-head", "endcard", "ec-headline",
             "ec-wincond", "ec-how", "ec-teams", "ec-replay", "status"]
  RemovedIds = ["#fpv", "#viewpanel", "#minimap", "#zoombar", "#zoom-",
                "fpv-canvas", "minimap-canvas"]
  ChromeAliases = ["markBeat", "renderBeatMarkers", "ingestBeats",
                   "renderClock", "renderTransport", "renderMomentum",
                   "ingestLeadSeries", "recordMomentum", "setVerdict",
                   "ingestLullSpans", "renderLullSpans", "togglePov",
                   "getSpoilers", "setSpoilers"]

proc pageParts(): tuple[head, block1: string] =
  let page = readFile(PagePath)
  let cut = page.find(Banner)
  doAssert cut > 0, "the appended game block's banner is missing"
  (page[0 ..< cut], page[cut .. page.high])

proc fnv1a(text: string): uint64 =
  ## FNV-1a over the raw bytes. A content digest, hand-rolled so the pin costs
  ## no dependency: `std/sha1` moved out of the standard library in Nim 2 and a
  ## byte-for-byte assertion must not be the thing that breaks on a toolchain
  ## bump.
  result = 14695981039346656037'u64
  for ch in text:
    result = result xor uint64(uint8(ch))
    result = result * 1099511628211'u64

proc chromeIsTheStarters() =
  ## The shared chrome is copied BYTE FOR BYTE from coworld-ctf. The digest
  ## below is the cheapest way to say "not one character changed"; when the
  ## starter is deliberately re-synced, update it in the same commit.
  doAssert fileExists(ChromePath)
  let text = readFile(ChromePath)
  doAssert text.len == 40022,
    "client/chrome_common.js is " & $text.len & " bytes, the starter's is 40022"
  doAssert fnv1a(text) == 15163071468075018486'u64,
    "client/chrome_common.js is NOT the starter's byte for byte (fnv1a " &
      $fnv1a(text) & ")"
  doAssert "window.ChromeCommon" in text
  doAssert "window.CTF_WIRE" in text,
    "the inherited chrome reads window.CTF_WIRE; wire_constants.nim aliases it"
  report "client/chrome_common.js is the starter's, byte for byte"

proc removedAndKeptIds() =
  let page = readFile(PagePath)
  for id in RemovedIds:
    doAssert id notin page, "a removed element survives: " & id
  for id in KeptIds:
    doAssert ("id=\"" & id & "\"") in page,
      "a kept element is missing: #" & id
  doAssert "?embed=1" in page or "data-embed" in page,
    "the ?embed=1 mode is kept"
  report "the fpv and view-panel ids are gone and every kept id survives"

proc appendedIdsAreFbPrefixed() =
  let (_, appended) = pageParts()
  var i = 0
  var found = 0
  while true:
    let at = appended.find("id=\"", i)
    if at < 0:
      break
    let stop = appended.find('"', at + 4)
    if stop < 0:
      break
    let id = appended[at + 4 ..< stop]
    doAssert id.startsWith("fb-"),
      "a new id in the game block is not fb-prefixed: " & id
    inc found
    i = stop + 1
  # The block also creates ids in JS with `el.id = 'fb-…'`.
  for marker in ["el.id = 'fb-half'", "el.id = 'fb-possbar'",
      "el.id = 'fb-goalreplay'"]:
    doAssert marker in appended, "the game block should create " & marker
  # The plate CONTENTS are built by the inherited page's own ensureScorebug,
  # behind FB_MODE, so their ids live above the banner — but they are this
  # game's nodes, so they carry the prefix too.
  let page = readFile(PagePath)
  doAssert "fb-shots-" in page and "fb-statline-" in page,
    "the football plate contents are missing"
  doAssert "fb-chip" in page and "fb-sub" in page and "fb-lbl" in page
  discard found
  report "every id this game introduces is fb-prefixed"

proc everyBeatKindHasCss() =
  let (_, appended) = pageParts()
  for kind in BeatKinds:
    doAssert (".beat-marker." & kind) in appended,
      "no CSS rule for the beat kind " & kind
  doAssert ".beat-marker.goal.red" in appended
  doAssert ".beat-marker.goal.blue" in appended
  doAssert "button.beat-marker" in appended,
    "beats are BUTTONS, not divs"
  doAssert "aria-label" in appended, "every beat marker is labelled"
  doAssert "CTX.send('s:' + tick)" in appended,
    "clicking a beat seeks to its tick"
  report "every emitted beat kind has a CSS rule and seeks on click"

proc tinyAndPlateNameRules() =
  let (_, appended) = pageParts()
  doAssert "#stage.tiny" in appended, "the .tiny block is missing"
  doAssert ".plate-name" in appended, "the .plate-name rule is missing"
  doAssert "flex: 1 1 auto" in appended
  doAssert "min-width: 3.2em" in appended
  doAssert "max-width: 640px" in appended,
    "labels must be hidden under 640px so the scorebug reads at 360px"
  report "the .tiny, .plate-name and 640px rules are present"

proc transportBandIsUntouched() =
  let page = readFile(PagePath)
  doAssert "--hudscale" in page and "--band" in page,
    "relayout() still owns --hudscale and --band"
  doAssert "bottom: var(--band, 0px)" in page,
    "the endcard still stops at the transport band"
  let (_, appended) = pageParts()
  doAssert "#transport" notin appended,
    "the appended block must never draw inside the transport band"
  report "the transport band is the starter's and nothing overlays it"

proc noAliasIsShadowed() =
  ## A game-block function sharing a name with the chrome alias block's hoisted
  ## `var` is silently swallowed (cogame-tandem, 2026-08-23).
  let (_, appended) = pageParts()
  for alias in ChromeAliases:
    doAssert ("function " & alias & "(") notin appended,
      "the game block shadows the chrome alias " & alias
    doAssert ("var " & alias & " ") notin appended
  report "the game block shadows none of the chrome's aliases"

proc bundleSourcesDoNotFetchThePodRoute() =
  ## The bundle must never OPEN the live-pod board route: it re-simulates in
  ## the browser and fetches nothing but the S3 replay object. (A prose mention
  ## of the route in a comment is fine; a src= or a fetch of it is not.)
  for path in ["client/replay_broadcast.html",
      "replay-viewer/static_replay.js",
      "replay-viewer/static_replay_worker.js"]:
    let text = readFile(path)
    for bad in ["src=\"/client/replay", "fetch('/client/replay",
        "fetch(\"/client/replay"]:
      doAssert bad notin text, path & " fetches the live-pod replay route"
  doAssert not fileExists("client/league_replayer.html"),
    "the League Replayer shell is deleted from this coworld"
  report "no bundle source fetches the live-pod replay route"

proc exportRenameIsConsistent() =
  ## Splicing one starter's shell onto another's link flags is what deadlocked
  ## cogame-lantern. The ctf_ -> grf_ rename must be consistent across the
  ## config, the worker, the wasm entry and the page adapter.
  let config = readFile("replay-viewer/config.nims")
  let worker = readFile("replay-viewer/static_replay_worker.js")
  let shell = readFile("replay-viewer/static_replay.js")
  let entry = readFile("replay-viewer/grf_football_replay.nim")
  let page = readFile(PagePath)
  for name in ["grf_load_replay", "grf_frame", "grf_input", "grf_packet_ptr",
      "grf_packet_len", "grf_mismatch_tick", "grf_error_ptr", "grf_error_len",
      "grf_stage_ptr", "grf_stage_len"]:
    doAssert name in config, "config.nims does not export " & name
    doAssert name in entry, "the wasm entry does not define " & name
  doAssert "Module._grf_frame" in worker
  doAssert "./grf_replay.js" in worker
  for text in [config, worker, shell, entry, page]:
    doAssert "ctf_" notin text, "a ctf_ export name survives the rename"
  doAssert "MODULARIZE" notin config,
    "the link flags stay non-MODULARIZE, matched by onRuntimeInitialized"
  doAssert "onRuntimeInitialized" in worker,
    "the worker bootstraps on onRuntimeInitialized"
  doAssert "data-replay-loaded" in shell,
    "the shell sets data-replay-loaded on its first drawn frame"
  doAssert "data-replay-error" in shell,
    "the shell sets data-replay-error on every failure path"
  report "the ctf_ -> grf_ rename is consistent and the link flags are ctf's"

when isMainModule:
  echo "test_viewer"
  chromeIsTheStarters()
  removedAndKeptIds()
  appendedIdsAreFbPrefixed()
  everyBeatKindHasCss()
  tinyAndPlateNameRules()
  transportBandIsUntouched()
  noAliasIsShadowed()
  bundleSourcesDoNotFetchThePodRoute()
  exportRenameIsConsistent()
  echo "test_viewer ok"
