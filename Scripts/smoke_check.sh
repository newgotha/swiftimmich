#!/bin/bash
# Launches a built SwiftImmich and checks two things before you release it:
#   1. it settles to idle after launch (a screen redrawing in a loop would not), and
#   2. the freeze watchdog really works: a forced 10-second freeze must leave a stack sample.
#
# Usage: Scripts/smoke_check.sh [path/to/SwiftImmich.app]   (default: dist/SwiftImmich.app)
# It quits any running SwiftImmich and may show a dialog in the app; close it, or let the script quit the app.
set -u
cd "$(dirname "$0")/.."
APP="${1:-dist/SwiftImmich.app}"
BUNDLE_ID=dev.local.swiftimmich
HANGS="$HOME/Library/Logs/SwiftImmich Hangs"
LOG="$HOME/Library/Logs/SwiftImmich.log"
FAILED=0

[ -d "$APP" ] || { echo "No app at $APP — run Scripts/package_release.sh first."; exit 2; }

pid() { pgrep -x SwiftImmich | head -1; }
quit_app() { pkill -x SwiftImmich 2>/dev/null; sleep 2; }
cpu() { ps -o %cpu= -p "$1" | tr -d ' ' | cut -d. -f1; }
pass() { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; FAILED=1; }

quit_app
defaults delete "$BUNDLE_ID" unreportedHangSample 2>/dev/null
defaults delete "$BUNDLE_ID" debugFreezeSeconds 2>/dev/null

echo "1. Idle after launch"
open "$APP"
sleep 15
P=$(pid)
if [ -z "$P" ]; then fail "the app isn't running (it quit or crashed)"; else
  BUSY=$(cpu "$P"); BUSY=${BUSY:-0}
  sleep 3; BUSY2=$(cpu "$P"); BUSY2=${BUSY2:-0}
  if [ "$BUSY" -lt 25 ] && [ "$BUSY2" -lt 25 ]; then pass "using ${BUSY}% / ${BUSY2}% of a core"; else fail "still using ${BUSY}% / ${BUSY2}% of a core"; fi
fi
quit_app

echo "2. The watchdog catches a forced freeze"
MARK=$(mktemp)
LOGSIZE=$(wc -c < "$LOG" 2>/dev/null || echo 0)
defaults write "$BUNDLE_ID" debugFreezeSeconds -float 10
open "$APP"
sleep 32
NEW=$(find "$HANGS" -name 'hang-*.txt' -newer "$MARK" 2>/dev/null | head -1)
rm -f "$MARK"
if [ -n "$NEW" ]; then pass "stack sample saved: $(basename "$NEW")"; else fail "no stack sample was saved"; fi
FREEZES=$(tail -c +$((LOGSIZE + 1)) "$LOG" 2>/dev/null | grep -c "stopped responding")
if [ "$FREEZES" = 1 ]; then pass "the log records the freeze once"; else fail "the log records $FREEZES freezes (expected exactly 1)"; fi
quit_app
defaults delete "$BUNDLE_ID" unreportedHangSample 2>/dev/null
defaults delete "$BUNDLE_ID" debugFreezeSeconds 2>/dev/null

echo
if [ "$FAILED" = 0 ]; then echo "Smoke check passed."; else echo "Smoke check FAILED."; fi
exit "$FAILED"
