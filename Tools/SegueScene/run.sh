#!/usr/bin/env bash
# AutoMix's transitions in the Mac app, for real: songs made by the app (124, 126 and 128 BPM) played
# from their files (LaunchScene "segue"). Each Segue plan is played ahead into a file (SegueRender):
# both songs' tempos glide, never in a step, and the file starts and ends on the songs' own samples.
# The player's log says the level chosen, what the render measured (the file against the songs at
# both ends, the largest change of speed from one frame to the next, the decks' jumps), how far the
# file's player was from the playing song as it took over (on the same music), and where the next
# song's own samples go on in the file (to its end). Live, the second mix (into the third song) must
# come too.
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
grep -q "segue: locked" "$work/live.log" || { echo "::error::The two songs weren't planned as a beat-matched mix"; failed=1; }
if grep -q "segue: render failed" "$work/live.log" "$work/alac.log"; then echo "::error::A Segue couldn't be played ahead (the live session ran instead)"; failed=1; fi
if grep -q "segue: arming" "$work/live.log" "$work/alac.log"; then echo "::error::The live session ran instead of the mix played ahead"; failed=1; fi
grep -q "segue-scene: next song" "$work/live.log" || { echo "::error::The next song didn't take over"; failed=1; }
grep -q "segue-scene: next song Segue C" "$work/live.log" || { echo "::error::The third song didn't take over"; failed=1; }
# What each render measured: the file exactly the songs' own samples where it takes over and hands
# back, no step in any speed, no jump in the decks' processing.
while read -r head tail step jumps; do
  echo "Rendered: head $head, tail $tail, largest speed step $step, jumps $jumps"
  if awk -v h="$head" -v t="$tail" 'BEGIN { exit !(h > 1e-6 || t > 1e-6) }'; then
    echo "::error::The mix's file isn't the songs' own samples where it takes over ($head) or hands back ($tail)"; failed=1
  fi
  if awk -v s="$step" 'BEGIN { exit !(s > 1e-4) }'; then echo "::error::A speed changed in a step ($step per frame)"; failed=1; fi
  [ "$jumps" -eq 0 ] || { echo "::error::The decks' processing jumped $jumps time(s)"; failed=1; }
done < <(grep -ho "segue: rendered .*" "$work/live.log" "$work/alac.log" \
  | sed -E 's/.* head ([-+0-9.e]+), tail ([-+0-9.e]+), largest speed step ([-+0-9.e]+), jumps ([0-9]+).*/\1 \2 \3 \4/')
# The rest of the next song written after the mix (decoded again) follows on from the mix's last frame
# exactly: the same samples as the first decoding where both hold them.
while read -r rest; do
  echo "The song's rest after the mix: $rest from its first decoding"
  if awk -v r="$rest" 'BEGIN { exit !(r > 1e-6) }'; then echo "::error::The song's rest in the mix's file doesn't follow on exactly ($rest)"; failed=1; fi
done < <(grep -ho "segue: rendered .*, rest [-+0-9.e]*" "$work/live.log" "$work/alac.log" | sed -E 's/.*, rest ([-+0-9.e]+)$/\1/')
rests=$(grep -c "segue: rendered .*, rest " "$work/live.log")
[ "$rests" -ge 2 ] || { echo "::error::Only $rests render(s) measured the song's rest"; failed=1; }
# The songs play at gains other than 1 ("Volume uniforme"), as real ones do: the renders must have had them.
gains=$(grep -ho "gains [0-9.]*/[0-9.]*" "$work/live.log" | sort -u | tr '\n' ' ')
echo "Gains in the mixes: $gains"
if ! grep -ho "gains [0-9.]*/[0-9.]*" "$work/live.log" | grep -qv "gains 1.00/1.00"; then
  echo "::error::The songs were mixed at a gain of 1: the scene doesn't cover Volume uniforme"; failed=1
fi
rendered=$(grep -c "segue: rendered" "$work/live.log")
[ "$rendered" -ge 2 ] || { echo "::error::Only $rendered mix(es) played ahead in three songs"; failed=1; }
grep -q "segue: rendered" "$work/alac.log" || { echo "::error::The mix wasn't played ahead on ALAC files"; failed=1; }
# The take-over: the file's player and the playing one on the same music, in phase (a few
# milliseconds apart would be a faint comb, ten a doubled beat).
while read -r apart; do
  echo "Take-over: $apart ms apart"
  if awk -v a="$apart" 'BEGIN { exit !((a < 0 ? -a : a) > 2) }'; then
    echo "::error::The mix's file took over $apart ms from the playing song (heard as a skip)"; failed=1
  fi
done < <(grep -ho "segue: take-over at [0-9.]* s, [-+0-9.]* ms apart" "$work/live.log" "$work/alac.log" | sed -E 's/.* s, ([-+0-9.]+) ms apart/\1/')
# The playing song goes out through its own stage, armed seconds ahead of the take-over (its audio is
# processed ahead of what is heard: armed late, it played on doubled with the file).
grep -ho "the playing song out by its .*" "$work/live.log" "$work/alac.log" | sed "s/^/Take-over: /"
if grep -q "the playing song out by its player's volume" "$work/live.log" "$work/alac.log"; then
  echo "::error::The playing song's fade wasn't armed in time on its stage"; failed=1
fi
takeovers=$(grep -c "segue: take-over" "$work/live.log")
[ "$takeovers" -ge 2 ] || { echo "::error::Only $takeovers take-over(s) measured in three songs"; failed=1; }
joined=$(grep -c "segue: joined" "$work/live.log")
[ "$joined" -ge 2 ] || { echo "::error::Only $joined mix(es) carried on into the next song's own samples"; failed=1; }
grep -q "segue: joined" "$work/alac.log" || { echo "::error::The ALAC mix didn't carry on into the next song's own samples"; failed=1; }
grep -q "segue-scene: next song" "$work/off.log" || { echo "::error::Without the live mix the next song didn't take over"; failed=1; }
# The earlier way's mix plays as one file too (the mix, then the song to its end at its gain).
grep -q "segue: the earlier way's mix in one file" "$work/off.log" || { echo "::error::The earlier way's mix wasn't made into one file"; failed=1; }
if grep -q "segue: \(arming\|rendered\)" "$work/off.log"; then echo "::error::A Segue ran while turned off"; failed=1; fi
# Beat This! in the app: the songs' beats from the model (a count, -1 without it).
if grep -q "segue: beats from the model: [1-9]" "$work/live.log"; then echo "The bars came from Beat This!"; else echo "::error::The songs were planned without Beat This!'s beats"; failed=1; fi
exit $failed
