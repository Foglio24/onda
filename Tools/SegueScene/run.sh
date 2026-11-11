#!/usr/bin/env bash
# AutoMix's live transition in the Mac app, for real: two songs made by the app (124 and 126 BPM)
# played from their files, the next one started on a second player in step with the first and
# mixed in (LaunchScene "segue"). The player's log says the level chosen and why, the second
# player's distance from its place when the window opened and the worst while both were heard.
# With "off" the live mix is turned off and the rendered mix must play instead; with "alac" the songs
# are Apple Lossless files.
# Usage: bash Tools/SegueScene/run.sh <Seaglass.app>
set -uo pipefail
app="$1"
binary="$app/Contents/MacOS/Seaglass"
work=$(mktemp -d)

run() {
  local name="$1" scene="$2"
  pkill -x Seaglass 2>/dev/null
  sleep 1
  NSUnbufferedIO=YES "$binary" -AppleLanguages "(en)" -SeaglassScene "$scene" >"$work/$name.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 150); do
    grep -q "segue-scene: \(done\|the next song never came\)" "$work/$name.log" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  pkill -x Seaglass 2>/dev/null
  sleep 1
  grep -e "segue" -e "automix" "$work/$name.log" | sed "s/^/[$name] /"
}

run live "segue"
run off "segue:off"
run alac "segue:alac"
failed=0
grep -q "segue: locked" "$work/live.log" || { echo "::error::The two songs weren't planned as a beat-matched live mix"; failed=1; }
grep -q "segue: window" "$work/live.log" || { echo "::error::The live mix's window never opened"; failed=1; }
grep -q "segue: mixed" "$work/live.log" || { echo "::error::The live mix didn't reach its end"; failed=1; }
grep -q "segue-scene: next song" "$work/live.log" || { echo "::error::The next song didn't take over"; failed=1; }
if grep -q "segue: \(lost\|dropped\)" "$work/live.log"; then echo "::warning::The live mix was left or dropped (see the log)"; fi
# The second player's worst distance from its place while both were heard: beats more than 30 ms
# apart start to flam, past 100 ms they are two beats.
worst=$(grep -o "segue: mixed .*worst [0-9]* ms" "$work/live.log" | grep -o "worst [0-9]*" | grep -o "[0-9]*$" | tail -1)
if [ -n "$worst" ]; then
  echo "Worst distance while heard: $worst ms"
  if [ "$worst" -gt 100 ]; then echo "::error::The next song drifted $worst ms from its place while heard"; failed=1
  elif [ "$worst" -gt 30 ]; then echo "::warning::The next song drifted $worst ms from its place while heard"; fi
fi
grep -q "segue-scene: next song" "$work/off.log" || { echo "::error::Without the live mix the next song didn't take over"; failed=1; }
grep -q "segue: mixed" "$work/alac.log" || { echo "::error::The live mix didn't run on Apple Lossless files"; failed=1; }
# Beat This! in the app: the songs' beats from the model (a count, -1 without it).
if grep -q "segue: beats from the model: [1-9]" "$work/live.log"; then echo "The bars came from Beat This!"; else echo "::error::The songs were planned without Beat This!'s beats"; failed=1; fi
if grep -q "segue: arming" "$work/off.log"; then echo "::error::The live mix ran while turned off"; failed=1; fi
exit $failed
