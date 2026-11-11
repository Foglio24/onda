#!/usr/bin/env bash
# AutoMix's live transition in the Mac app, for real: songs made by the app (124, 126 and 128 BPM)
# played from their files, each next one started on a second player in step with the one playing
# and mixed in (LaunchScene "segue"). The player's log says the level chosen and why, the second
# player's distance from its place when the window opened and the worst while both were heard, and
# whether the playing song was carried out at the next one's tempo. Live, the second mix (into the third song) must come too.
# With "off" the live mix is turned off and the rendered mix must play instead; with "alac" the songs
# are ALAC files.
# Usage: bash Tools/SegueScene/run.sh <Seaglass.app>
set -uo pipefail
app="$1"
binary="$app/Contents/MacOS/Seaglass"
work=$(mktemp -d)

run() {
  local name="$1" scene="$2" seconds="$3"
  pkill -x Seaglass 2>/dev/null
  sleep 1
  NSUnbufferedIO=YES "$binary" -AppleLanguages "(en)" -SeaglassScene "$scene" >"$work/$name.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 "$seconds"); do
    grep -q "segue-scene: \(done\|the next song never came\)" "$work/$name.log" && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  pkill -x Seaglass 2>/dev/null
  sleep 1
  grep -e "segue" -e "automix" "$work/$name.log" | sed "s/^/[$name] /"
}

run live "segue" 330
run off "segue:off" 150
run alac "segue:alac" 150
failed=0
grep -q "segue: locked" "$work/live.log" || { echo "::error::The two songs weren't planned as a beat-matched live mix"; failed=1; }
grep -q "segue: window" "$work/live.log" || { echo "::error::The live mix's window never opened"; failed=1; }
grep -q "segue: mixed" "$work/live.log" || { echo "::error::The live mix didn't reach its end"; failed=1; }
grep -q "segue-scene: next song" "$work/live.log" || { echo "::error::The next song didn't take over"; failed=1; }
# A beat-matched mix carries the playing song out on a fresh player at the next one's tempo, and the
# next song plays at its own speed and sound from its first note: nothing to change once the mix is
# over. Its own transition into the next follows: a finished mix must not hold the next one back.
grep -q "segue: after the window" "$work/live.log" || { echo "::error::The live mix never finished after its window"; failed=1; }
carried=$(grep -c "segue: window .*the playing song carried at" "$work/live.log")
[ "$carried" -ge 2 ] || { echo "::error::The playing song was carried at the next one's tempo in $carried of 2 mixes"; failed=1; }
# 126 to 124 BPM and 128 to 126 (1.6 %): the playing song glides there in steps of half a percent.
glide=$(grep -o "the playing song carried at [0-9.]* in [0-9]* steps" "$work/live.log" | grep -o "in [0-9]* steps" | grep -o "[0-9]*" | sort -n | head -1)
if [ -z "$glide" ] || [ "$glide" -lt 2 ]; then echo "::error::The playing song's glide to the next tempo took ${glide:-no} steps"; failed=1; fi
own=$(grep -c "after the window: plays on at rate 1.0000" "$work/live.log")
[ "$own" -ge 2 ] || { echo "::error::The song brought in played at its own speed after $own of 2 mixes"; failed=1; }
mixes=$(grep -c "segue: mixed" "$work/live.log")
[ "$mixes" -ge 2 ] || { echo "::error::Only $mixes live mix(es) in three songs: the next transition didn't come after the first"; failed=1; }
grep -q "segue-scene: next song Segue C" "$work/live.log" || { echo "::error::The third song didn't take over"; failed=1; }
# How often the players rendered their sound again (each change of a player's rate does): the
# speed changes while the next song was heard (only while it is still quiet), and the jumps in each
# deck's samples. Informative: the speakers aren't measured.
grep -o "segue: after the window.*" "$work/live.log" | sed "s/^segue: after the window: /After the window: /"
heard=$(grep -o "heard with [0-9]* speed changes" "$work/live.log" | grep -o "[0-9]*" | sort -n | tail -1)
if [ -n "$heard" ] && [ "$heard" -gt 4 ]; then echo "::warning::The next song's speed changed $heard times while heard"; fi
if grep -q "segue: \(lost\|dropped\)" "$work/live.log"; then echo "::warning::The live mix was left or dropped (see the log)"; fi
# The second player's worst distance from its place while both were heard: beats more than 30 ms
# apart start to flam, past 100 ms they are two beats.
worst=$(grep -o "segue: mixed .*worst [0-9]* ms" "$work/live.log" | grep -o "worst [0-9]*" | grep -o "[0-9]*$" | sort -n | tail -1)
if [ -n "$worst" ]; then
  echo "Worst distance while heard: $worst ms"
  if [ "$worst" -gt 100 ]; then echo "::error::The next song drifted $worst ms from its place while heard"; failed=1
  elif [ "$worst" -gt 30 ]; then echo "::warning::The next song drifted $worst ms from its place while heard"; fi
fi
grep -q "segue-scene: next song" "$work/off.log" || { echo "::error::Without the live mix the next song didn't take over"; failed=1; }
grep -q "segue: mixed" "$work/alac.log" || { echo "::error::The live mix didn't run on ALAC files"; failed=1; }
# Beat This! in the app: the songs' beats from the model (a count, -1 without it).
if grep -q "segue: beats from the model: [1-9]" "$work/live.log"; then echo "The bars came from Beat This!"; else echo "::error::The songs were planned without Beat This!'s beats"; failed=1; fi
if grep -q "segue: arming" "$work/off.log"; then echo "::error::The live mix ran while turned off"; failed=1; fi
exit $failed
