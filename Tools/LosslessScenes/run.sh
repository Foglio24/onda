#!/usr/bin/env bash
# Lossless sources in the Mac app, for real: lossless files made here (FLAC 24 bit/96 kHz, ALAC
# 16 bit/44.1 kHz, and an AAC file that must be refused) imported and played, one of them broken
# so that it no longer decodes; and, with "live", the public Navidrome demo server: a FLAC found
# and streamed, a server that doesn't answer, and a stream cut off while playing.
# Usage: bash Tools/LosslessScenes/run.sh <Seaglass.app> files|live
set -uo pipefail
app="$1"
mode="$2"
binary="$app/Contents/MacOS/Seaglass"
work=$(mktemp -d)
logs="$work/logs"
mkdir -p "$logs" "$work/files" "$work/broken"

# shot <name> <seconds> <scene> [arguments]: the app at a scene, its log kept.
run() {
  local name="$1" wait="$2" scene="$3"
  shift 3
  pkill -x Seaglass 2>/dev/null
  sleep 1
  NSUnbufferedIO=YES "$binary" -AppleLanguages "(en)" -SeaglassScene "$scene" "$@" >"$logs/$name.log" 2>&1 &
  sleep "$wait"
  pkill -x Seaglass 2>/dev/null
  sleep 1
  grep -e "lossless" "$logs/$name.log" | sed "s/^/[$name] /"
}

if [ "$mode" = "files" ]; then
  python3 - "$work" <<'PY'
import math, struct, sys, wave
work = sys.argv[1]
def tone(path, rate, width, seconds=12):
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(width); w.setframerate(rate)
        peak = (1 << (8 * width - 1)) - 1
        frames = bytearray()
        for i in range(int(rate * seconds)):
            t = i / rate
            v = 0.3 * math.sin(2 * math.pi * 220 * t) + 0.2 * math.sin(2 * math.pi * 330 * t)
            sample = int(v * peak)
            frames += sample.to_bytes(width, "little", signed=True) * 2
        w.writeframes(bytes(frames))
tone(f"{work}/hires.wav", 96000, 3)
tone(f"{work}/cd.wav", 44100, 2)
PY
  afconvert -f flac -d flac "$work/hires.wav" "$work/files/Seaglass Demo - Hi-Res Tone.flac" || echo "::warning::afconvert could not make FLAC"
  afconvert -f m4af -d alac "$work/cd.wav" "$work/files/Seaglass Demo - CD Tone.m4a" || echo "::warning::afconvert could not make ALAC"
  afconvert -f m4af -d aac -b 128000 "$work/cd.wav" "$work/files/Seaglass Demo - Lossy Tone.m4a"
  cp "$work/files/Seaglass Demo - Hi-Res Tone.flac" "$work/broken/Seaglass Demo - Broken Tone.flac"
  afinfo "$work/files/Seaglass Demo - Hi-Res Tone.flac" | grep -i -e "format" -e "bit" | head -4
  run files 14 "lossless:files:$work/files"
  run broken 12 "lossless:broken:$work/broken"
  failed=0
  grep -q "lossless-scene: files imported 2" "$logs/files.log" || { echo "::error::The two lossless files weren't both imported (and the AAC refused)"; failed=1; }
  grep -q "FLAC · 24 bit/96 kHz" "$logs/files.log" || { echo "::error::The FLAC's 24 bit/96 kHz wasn't read"; failed=1; }
  grep -q "ALAC · 16 bit/44" "$logs/files.log" || { echo "::error::The ALAC's 16 bit/44.1 kHz wasn't read"; failed=1; }
  grep -q "lossless: verified" "$logs/files.log" || { echo "::error::The imported file didn't play"; failed=1; }
  grep -q "lossless: fallback" "$logs/broken.log" || { echo "::error::A file that doesn't decode didn't hand over"; failed=1; }
  exit $failed
fi

# Live: the public Navidrome demo (its documented demo login), never the app's own settings.
demo=(-SeaglassSubsonicServer https://demo.navidrome.org -SeaglassSubsonicUser demo -SeaglassSubsonicPassword demo)
run server 20 "lossless:server" "${demo[@]}"
run timeout 20 "lossless:timeout" -SeaglassSubsonicServer https://10.255.255.1 -SeaglassSubsonicUser demo -SeaglassSubsonicPassword demo
run dropout 24 "lossless:dropout" "${demo[@]}"
grep -q "lossless: verified FLAC" "$logs/server.log" || echo "::warning::The demo server's FLAC wasn't streamed (live)"
grep -q "lossless: choice in [0-3]\.[0-9] s: none" "$logs/timeout.log" || echo "::warning::A server that doesn't answer held the song up (live)"
grep -q "lossless: fallback (simulated dropout)" "$logs/dropout.log" || echo "::warning::A cut stream didn't hand over (live)"
exit 0
