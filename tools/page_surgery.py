#!/usr/bin/env python3
"""Surgery on the inherited coworld-ctf broadcast page.

The page is the STARTER'S, edited only where the design note says:
  * the first-person picture-in-picture (#fpv and its raycast renderer) goes —
    football has no first-person view, and `pov` stays in the state JSON at -1;
  * #viewpanel (zoom bar + minimap) goes — the pitch is a FIXED arena, the whole
    1200x800 board is always letterboxed into the frame, so there is nothing to
    zoom into and nothing to locate;
  * the ctf_ -> grf_ rename sweep reaches the page's WASM adapter name;
  * the paintball game block at the end is replaced by the football one.
Everything else — the CSS, the markup, relayout(), the transport, the scrubber,
the endcard, the ?embed=1 mode — is the starter's, untouched.
"""
import re
import sys

PAGE = "client/replay_broadcast.html"
SCRIPT_OFFSET = 1603          # page line = script line + this


def lines_of(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read().split("\n")


def chunk(all_lines, first, last):
    """The exact text of page lines [first, last], 1-based inclusive."""
    return "\n".join(all_lines[first - 1:last]) + "\n"


def drop(text, piece, what):
    if piece not in text:
        sys.exit("surgery: could not find %s" % what)
    return text.replace(piece, "", 1)


def swap(text, old, new, what):
    if old not in text:
        sys.exit("surgery: could not find %s" % what)
    return text.replace(old, new, 1)


page = open(PAGE, encoding="utf-8").read()
L = page.split("\n")

# ---- 1. CSS: the FPV inset and the zoom/minimap view controls --------------
page = drop(page, chunk(L, 548, 833), "the FPV + view-controls CSS")
page = drop(page, chunk(L, 1451, 1459), "the viewpanel opt-out CSS")

# ---- 2. markup: #viewpanel and #fpv ---------------------------------------
page = drop(page, chunk(L, 1505, 1523), "the #viewpanel markup")
page = drop(page, chunk(L, 1526, 1549), "the #fpv markup")

# ---- 3. script: the eye-level billboard art (FPV only) --------------------
page = swap(page, chunk(L, SCRIPT_OFFSET + 37, SCRIPT_OFFSET + 98), """
  // COG_BASE, not a root-absolute "/client/…": this page is served from THREE
  // places and a leading slash is only correct at one of them.
  //  - native server, bare:      /client/replay        → "" + /client/…
  //  - native server, proxied:   /<prefix>/client/replay (Kubernetes service
  //    proxy) — a leading slash would drop <prefix> and 404.
  //  - the STATIC WASM BUNDLE:   /v2/coworlds/replays/static/<coworld>/<hash>/
  //    index.html, where the assets sit NEXT TO the page and there is no server
  //    at all — a leading slash resolves to the API origin root and 404s.
  // Stripping the trailing "/client/<page>" recovers the prefix, so the same
  // expression serves all three. The bundle is detected by its WASM adapter
  // rather than a URL param: window.GrfStaticReplay only exists when
  // static_replay.js is on the page.
  var COG_BASE = window.GrfStaticReplay
    ? '.'
    : location.pathname.replace(/\\/clients?\\/[^/]*$/, '') + '/client';
""", "the eye-level billboard art block")

# ---- 4. script: the first-person renderer ---------------------------------
page = drop(page, chunk(L, SCRIPT_OFFSET + 749, SCRIPT_OFFSET + 749),
            "the renderFpv call")
page = drop(page, chunk(L, SCRIPT_OFFSET + 751, SCRIPT_OFFSET + 1863),
            "the first-person renderer")

# ---- 5. script: the minimap RLE decoder (FPV tactical map only) -----------
page = drop(page, chunk(L, SCRIPT_OFFSET + 462, SCRIPT_OFFSET + 462),
            "the ingestFpMap call")
page = drop(page, chunk(L, SCRIPT_OFFSET + 479, SCRIPT_OFFSET + 512),
            "the ingestFpMap decoder")

# ---- 6. script: the zoom cluster + minimap wiring -------------------------
page = swap(page, chunk(L, SCRIPT_OFFSET + 2529, SCRIPT_OFFSET + 2645), """  // ---- view controls: FIXED ARENA ---------------------------------------
  // The starter's zoom cluster and minimap (#viewpanel) are removed: the whole
  // 1200x800 pitch is always letterboxed into the frame, so there is nothing
  // off-screen to locate and nothing to zoom into. The keyboard's z / x / arrow
  // handlers below still drive core.zoomAt / core.panBy for a viewer who wants
  // a closer look at a scramble, so the two constants and the pan cell they
  // need survive; syncViewUi becomes the no-op the core's callbacks expect.
  var ZOOM_STEP = 1.35;     // one z or x key
  var PAN_CELL_MAP_PX = 64; // one arrow press, in LOGICAL map pixels

  function panCellBoardPx() {
    var bs = lastState && lastState.bs > 0 ? lastState.bs : 1;
    return PAN_CELL_MAP_PX * bs;
  }

  function syncViewUi(t) { void t; }

""", "the view-controls section")

# ---- 7. the ctf_ -> grf_ rename sweep reaches the page's adapter ----------
page = page.replace("window.CtfStaticReplay", "window.GrfStaticReplay")

# ---- 8. the game block is football's, not paintball's ---------------------
page = page.replace("PB_MODE", "FB_MODE")
page = page.replace("PB_CTX", "FB_CTX")
page = page.replace("PaintballChrome", "FootballChrome")

open(PAGE, "w", encoding="utf-8").write(page)
print("page surgery ok: %d lines" % len(page.split("\n")))
