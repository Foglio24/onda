#!/usr/bin/env bash
# The player close button must sit below the titlebar, receive clicks and dismiss its cover.
set -euo pipefail
app="$1"
work=$(mktemp -d)
pid=""
cleanup() {
  if [[ -n "$pid" ]]; then kill "$pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
NSUnbufferedIO=YES "$app/Contents/MacOS/Seaglass" -SeaglassScene player-close >"$work/check.log" 2>&1 &
pid=$!
for _ in $(seq 1 20); do
  if grep -q 'player-close: PASS' "$work/check.log"; then
    cat "$work/check.log"
    kill -0 "$pid"
    exit 0
  fi
  if grep -q 'player-close: FAIL' "$work/check.log" || ! kill -0 "$pid" 2>/dev/null; then break; fi
  sleep 1
done
cat "$work/check.log"
echo "The player close button check failed"
exit 1
