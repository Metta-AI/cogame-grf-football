## RELEASE-ONLY. A whole match of physics plus the control layer must finish
## well inside the episode's budget: 5760 ticks in under 120 s, which is four
## times the 30 s target and still an order of magnitude inside the engine's
## 690 s wall-clock stop.

import std/[monotimes, times]
import lib/helpers

when isMainModule:
  echo "test_perf"
  let config = testConfig(maxTicks = DefaultMaxTicks)
  let started = getMonoTime()
  let match = runScriptedMatch(config)
  let elapsed = (getMonoTime() - started).inMilliseconds
  echo "  5760 ticks in ", elapsed, " ms (", match.goals[Red], "-",
    match.goals[Blue], ", ", $match.rule, ")"
  doAssert match.ticks >= DefaultMaxTicks,
    "the match must play out, got " & $match.ticks & " ticks"
  doAssert elapsed < 120_000,
    "a full match took " & $elapsed & " ms; the bound is 120 s"
  report "5760 ticks of physics plus control inside 120 s"
  echo "test_perf ok"
