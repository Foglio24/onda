#!/usr/bin/env bash
# The features that play, sort, collect and count songs, checked in the Mac app for real (the same code
# as on an iPhone): each LaunchScene scene below drives one and logs "<name>: ok …" or "<name>: FAIL …"
# for each thing it checks, then "<name>: PASS" or "<name>: FAIL", then "<name>: done".
# - automix-demo-check: the Home's AutoMix demo played over a queue that plays, then closed: the
#   queue, its song and its position as they were, playing on; a paused queue stays paused; the
#   demo's songs never in the history.
# - mix-order-check: "Ordina per il mix" on a playlist analysed in part (two songs not downloaded,
#   one unreadable file, one song without a beat): the six on the device ordered, the others kept at
#   the end, nothing invented, a passage heard, every song in the new playlist, the original unchanged.
# - smart-check: the library's smart collections on songs played, liked and downloaded here.
# Usage: bash Tools/FeatureScenes/run.sh <Seaglass.app>
set -uo pipefail
app="$1"
binary="$app/Contents/MacOS/Seaglass"
work=$(mktemp -d)
failed=0

run() {
  local scene="$1" name="$2" seconds="$3"
  pkill -x Seaglass 2>/dev/null
  sleep 1
  NSUnbufferedIO=YES "$binary" -AppleLanguages "(en)" -SeaglassScene "$scene" >"$work/$scene.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 "$seconds"); do
    grep -q "^$name: done" "$work/$scene.log" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  pkill -x Seaglass 2>/dev/null
  sleep 1
  grep "^$name: " "$work/$scene.log" | sed "s/^/[$scene] /"
  if ! grep -q "^$name: PASS" "$work/$scene.log"; then
    echo "::error::$scene didn't pass"
    tail -40 "$work/$scene.log"
    failed=1
  fi
}

run automix-demo-check automix-demo 300
run mix-order-check mix-order 300
run smart-check smart 120
rm -rf "$work"
exit "$failed"
