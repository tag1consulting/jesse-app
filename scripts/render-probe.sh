#!/usr/bin/env bash
#
# render-probe.sh — count SwiftUI body evaluations per action, from a simulator's log.
#
# The app logs one `notice` per body evaluation when `JESSE_RENDER_PROBE=1` is in its
# environment (see `RenderProbe`), and `UnreadBadgeRenderUITests` logs a `mark <label>`
# around each action it drives. Both land in the same subsystem, so the run is one
# interleaved timeline; this reads it back and counts the body lines between each
# `<label>-begin` and `<label>-end`.
#
# Usage:
#     scripts/render-probe.sh [simulator-udid] [minutes-back]
#
# With no udid it uses the booted simulator. `minutes-back` defaults to 30 — long enough
# to cover the whole UI test run, which takes minutes on a store of 300 conversations.
#
# Run the measurement itself with:
#     xcrun simctl uninstall <udid> com.tag1.Jesse     # an EMPTY store, or the run counts
#                                                      # the last run's conversations too
#     xcodebuild test -scheme Jesse -destination "platform=iOS Simulator,id=<udid>" \
#       -only-testing:JesseUITests/UnreadBadgeRenderUITests CODE_SIGNING_ALLOWED=NO
# and then this script against the same udid.
set -uo pipefail

UDID="${1:-booted}"
MINUTES="${2:-30}"

raw="$(xcrun simctl spawn "$UDID" log show \
        --style compact \
        --last "${MINUTES}m" \
        --predicate 'subsystem == "com.tag1.jesse" AND category == "render"' 2>/dev/null)"

if [ -z "$raw" ]; then
  echo "render-probe: no render lines in the last ${MINUTES}m on ${UDID}." >&2
  echo "  Was JESSE_RENDER_PROBE=1 set in the app's launch environment?" >&2
  exit 1
fi

printf '%s\n' "$raw" | awk '
  # Each line is one log record; the message is its tail. Pick out the two shapes the
  # probe emits and ignore everything else (timestamps, process names, thread ids).
  #
  # ONLY THE LAST RUN COUNTS. The log window is measured in minutes and a run takes under
  # one, so a window wide enough to be safe holds several runs — and a before/after
  # comparison that silently summed two of them is exactly the wrong answer. The first
  # window of a run (`launch`) resets everything, so what is reported is the most recent
  # run and nothing else.
  /mark launch-begin/    { delete count; delete total; delete seen; delete name; order = 0 }
  /mark [a-z-]+-begin/   { match($0, /mark [a-z-]+-begin/);  w = substr($0, RSTART+5, RLENGTH-5);
                           sub(/-begin$/, "", w); window = w; next }
  /mark [a-z-]+-end/     { window = ""; next }
  /body [A-Za-z]+/       { if (window == "") next
                           match($0, /body [A-Za-z]+/); v = substr($0, RSTART+5, RLENGTH-5)
                           count[window "|" v]++; total[window]++
                           if (!(window in seen)) { seen[window] = ++order; name[order] = window }
                           next }
  END {
    for (i = 1; i <= length(name); i++) {
      w = name[i]
      printf "\n%s: %d body evaluations\n", w, total[w]
      for (k in count) {
        split(k, parts, "|")
        if (parts[1] == w) printf "    %-18s %d\n", parts[2], count[k]
      }
    }
    if (length(name) == 0) print "no marked windows found — the test may not have run"
  }
'
