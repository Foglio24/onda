#!/usr/bin/env bash
# The user's own songs on an iPhone, for real, in the simulator: files of every kind the app reads (WAV,
# AIFF, AAC and ALAC in M4A, FLAC, MP3 with and without tags and a cover, one in a subfolder) are put in
# the app's Documents/Musica (Files: Sul mio iPhone › Seaglass › Musica), as a person copies them there;
# then the app is opened on LaunchScene "local", which says what it found and plays each song for a few
# seconds. The step fails when a song isn't found or doesn't play.
# Usage: bash Tools/LocalScene/run.sh <Seaglass.app built for the simulator> <output folder>
set -uo pipefail
app="$1"
out="${2:-local-scene}"
mkdir -p "$out"
work=$(mktemp -d)

device=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
phones = [d for runtime, list_ in sorted(devices.items()) if "iOS" in runtime for d in list_ if d["name"].startswith("iPhone")]
pro = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]]
print((pro or phones)[-1]["udid"])')
echo "Simulator: $device"
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl install "$device" "$app"

# The songs: a short tune, then the same in every container.
python3 - "$work/tune.wav" <<'PY'
import math, struct, sys, wave
rate = 44100
notes = [261.63, 329.63, 392.0, 523.25]
frames = bytearray()
for i in range(rate * 12):
    f = notes[(i // (rate // 2)) % 4]
    v = 0.4 * math.sin(2 * math.pi * f * i / rate) * (0.6 + 0.4 * math.sin(2 * math.pi * 2 * i / rate))
    s = int(max(-1, min(1, v)) * 32767)
    frames += struct.pack('<hh', s, s)
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate); w.writeframes(bytes(frames))
PY
songs="$work/Musica"
mkdir -p "$songs/Album"
cp "$work/tune.wav" "$songs/01 Wave.wav"
afconvert -f AIFF -d BEI16 "$work/tune.wav" "$songs/02 Aiff.aiff"
afconvert -f m4af -d aac -b 192000 "$work/tune.wav" "$songs/03 Aac.m4a"
afconvert -f m4af -d alac "$work/tune.wav" "$songs/04 Alac.m4a"
afconvert -f flac -d flac "$work/tune.wav" "$songs/05 Flac.flac" || echo "::warning::afconvert couldn't make a FLAC file"
sips -s format jpeg -Z 300 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns \
  --out "$work/cover.jpg" >/dev/null 2>&1 || true
if command -v lame >/dev/null; then
  cover=()
  [ -f "$work/cover.jpg" ] && cover=(--ti "$work/cover.jpg")
  lame --quiet -b 192 --tt "Mp3 With Tags" --ta "Test Artist" --tl "Test Album" "${cover[@]}" "$work/tune.wav" "$songs/06 Mp3 Tags.mp3"
  lame --quiet -b 128 "$work/tune.wav" "$songs/07 Mp3 No Tags.mp3"
  lame --quiet -b 160 "$work/tune.wav" "$songs/Album/08 Nested.mp3"
else
  echo "::warning::lame isn't installed: no MP3 files"
fi
# A folder "chosen with the picker" (the scene adds it as a bookmark), beside the app's own Musica.
picked="$work/Picked"
mkdir -p "$picked"
afconvert -f m4af -d aac "$work/tune.wav" "$picked/P1 Picked.m4a"
cp "$work/tune.wav" "$picked/P2 Picked.wav"
expected=$(( $(find "$songs" -type f | wc -l) + $(find "$picked" -type f | wc -l) ))
ls -lR "$songs" "$picked"

container=$(xcrun simctl get_app_container "$device" com.onda.player data)
mkdir -p "$container/Documents/Musica" "$container/Documents/Picked"
cp -R "$songs/." "$container/Documents/Musica/"
cp -R "$picked/." "$container/Documents/Picked/"

xcrun simctl launch --terminate-running-process --console-pty "$device" com.onda.player \
  -AppleLanguages "(it)" -SeaglassScene local >"$work/app.log" 2>&1 &
for _ in $(seq 1 240); do
  grep -q "local-scene: done" "$work/app.log" && break
  sleep 1
done
xcrun simctl io "$device" screenshot "$out/local-player.png" >/dev/null 2>&1 || true
xcrun simctl terminate "$device" com.onda.player >/dev/null 2>&1 || true
cp "$work/app.log" "$out/app.log"
grep "local-scene" "$work/app.log"

failed=0
found=$(grep -o "local-scene: found [0-9]*" "$work/app.log" | grep -o "[0-9]*$" | tail -1)
plays=$(grep -c "local-scene: PLAYS" "$work/app.log")
fails=$(grep -c "local-scene: FAILS" "$work/app.log")
echo "Files: $expected, found: ${found:-none}, played: $plays, failed: $fails"
grep -q "local-scene: done" "$work/app.log" || { echo "::error::The scene never finished (see app.log)"; failed=1; }
[ "${found:-0}" -eq "$expected" ] || { echo "::error::The app found ${found:-no} of the $expected files in Documents/Musica"; failed=1; }
[ "$fails" -eq 0 ] || { echo "::error::$fails of the songs didn't play"; failed=1; }
# A song whose file has gone says so, in the app's words, and isn't looked for on YouTube.
gone=$(grep -o "local-scene: gone .*" "$work/app.log" | tail -1)
echo "${gone:-no line for the song whose file has gone}"
if echo "$gone" | grep -qi "video"; then echo "::error::A song of the user's own was looked for on YouTube ($gone)"; failed=1; fi
echo "$gone" | grep -q "non si apre" || { echo "::error::A song whose file has gone doesn't say so ($gone)"; failed=1; }
xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
exit $failed
