#!/usr/bin/env bash
# AutoMix's live transition in the Mac app, for real: songs made by the app (124, 126 and 128 BPM)
# played from their files, each next one started on a second player in step with the one playing
# and mixed in (LaunchScene "segue"). The player's log says the level chosen and why, the second
# player's distance from its place when the window opened and the worst while both were heard, and
# that nothing heard jumped. Live, the second mix (into the third song) must come too.
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
# A beat-matched mix stretches the next song, started silent at the playing one's tempo, then brings
# it back to its own speed on a fresh player after the window (keeping it stretched left the wrong
# tempo until pause/stop). The playing song is never carried on other players (each step was heard
# as a skip). Its own transition into the next follows: a finished mix must not hold the next one back.
grep -q "segue: after the window" "$work/live.log" || { echo "::error::The live mix never finished after its window"; failed=1; }
if grep -q "the playing song carried at" "$work/live.log"; then echo "::error::The playing song was carried on players a step (heard as skips)"; failed=1; fi
fresh=$(grep -c "after the window: .*back to its own speed on a fresh player" "$work/live.log")
[ "$fresh" -ge 2 ] || { echo "::error::Only $fresh mix(es) brought the next song back to its own speed"; failed=1; }
# Nothing heard may jump: neither deck from when the next song is loud in the mix to the window's
# end, nor the playing song's anywhere in the window (its player is never touched).
while read -r loud_in loud_out; do
  if [ "$loud_in" -ne 0 ] || [ "$loud_out" -ne 0 ]; then
    echo "::error::A deck jumped while heard loud in a mix: next song $loud_in, playing song $loud_out"; failed=1
  fi
done < <(grep -o "jumps while loud: incoming [0-9]*, outgoing [0-9]*" "$work/live.log" "$work/alac.log" | grep -o "[0-9]*, outgoing [0-9]*" | sed "s/, outgoing / /")
while read -r out_jumps; do
  if [ "$out_jumps" -ne 0 ]; then echo "::error::The playing song's deck jumped $out_jumps time(s) in a mix's window"; failed=1; fi
done < <(grep -o "deck jumps in the window: incoming [0-9]*, outgoing [0-9]*" "$work/live.log" "$work/alac.log" | grep -o "outgoing [0-9]*" | grep -o "[0-9]*")
loud_lines=$(grep -c "jumps while loud" "$work/live.log")
[ "$loud_lines" -ge 2 ] || { echo "::error::Only $loud_lines mix(es) reported their jumps while loud"; failed=1; }
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
