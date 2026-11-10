#!/usr/bin/env bash
# Opens Seaglass for Mac at a few screens (see Seaglass/App/LaunchScene.swift) and saves a picture
# of its window each time, as run.sh does on the simulators. In English, in dark mode.
# Usage: bash Tools/Screenshots/mac.sh <Seaglass.app built for Mac> <output folder>
set -uo pipefail
app="$1"
out="$2"
mkdir -p "$out"
binary="$app/Contents/MacOS/Seaglass"

# A small tool that prints the number of Seaglass's main window, for screencapture -l.
tools=$(mktemp -d)
cat > "$tools/window.swift" <<'SWIFT'
import CoreGraphics

let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] ?? []
func area(_ window: [String: Any]) -> Double {
    let bounds = window[kCGWindowBounds as String] as? [String: Double] ?? [:]
    return (bounds["Width"] ?? 0) * (bounds["Height"] ?? 0)
}
let ours = windows.filter {
    ($0[kCGWindowOwnerName as String] as? String) == "Seaglass" && ($0[kCGWindowLayer as String] as? Int) == 0
}
if let window = ours.max(by: { area($0) < area($1) }), let number = window[kCGWindowNumber as String] {
    print(number)
}
SWIFT
swiftc -O "$tools/window.swift" -o "$tools/window" || true

logs=$(mktemp -d)

# The newest crash report of Seaglass, if there is one: why it stopped and where.
crash() {
  sleep 3
  local report
  report=$(ls -t "$HOME"/Library/Logs/DiagnosticReports/Seaglass*.ips 2>/dev/null | head -1)
  [ -n "$report" ] || { echo "No crash report"; return; }
  echo "Crash report: $report"
  python3 - "$report" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
header, _, body = text.partition("\n")
report = json.loads(body)
print("exception:", report.get("exception"))
print("termination:", report.get("termination", {}).get("indicator"), report.get("termination", {}).get("reasons"))
for key in ("asi", "lastExceptionBacktrace"):
    if key in report:
        print(key, json.dumps(report[key])[:1500])
images = report.get("usedImages", [])
thread = report["threads"][report.get("faultingThread", 0)]
print("thread:", thread.get("name") or thread.get("queue"))
for frame in thread.get("frames", [])[:40]:
    image = images[frame["imageIndex"]].get("name", "?") if frame.get("imageIndex", -1) < len(images) else "?"
    print(f'  {image:28} {frame.get("symbol", hex(frame.get("imageOffset", 0)))} +{frame.get("symbolLocation", 0)}', frame.get("sourceFile", ""), frame.get("sourceLine", ""))
PY
  rm -f "$report"
}

# shot <file name> <seconds to wait> <scene> [more launch arguments]
shot() {
  local name="$1" wait="$2" scene="$3"
  shift 3
  pkill -x Seaglass 2>/dev/null
  sleep 1
  # Unbuffered, so its output is in the log even though it's stopped with a signal.
  NSUnbufferedIO=YES "$binary" -AppleLanguages "(en)" -AppleInterfaceStyle Dark -SeaglassScene "$scene" "$@" \
    >"$logs/$name.log" 2>&1 &
  local pid=$!
  sleep "$wait"
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "::warning::Seaglass quit at $name"
    grep -i -E "fatal|error|exception|assert" "$logs/$name.log" | tail -20
    crash
  fi
  local window=""
  [ -x "$tools/window" ] && window=$("$tools/window")
  if [ -n "$window" ]; then
    screencapture -x -o -l"$window" "$out/$name.png" && echo "Saved $name (window $window)"
  else
    screencapture -x "$out/$name.png" && echo "Saved $name (whole screen: no window found)"
  fi
}

shot mac-1-home 16 home
# The whole screen too: Seaglass's note in the menu bar (the AppKit plug-in), on the right.
screencapture -x -m "$out/mac-0-screen.png" && echo "Saved the screen"
shot mac-2-player 16 "player:K0HSD_i2DvA"
shot mac-3-player-queue 16 "player:K0HSD_i2DvA" -SeaglassPanel queue
# The same player at both bounds: cover sizing and lyrics/queue type must follow the window.
shot mac-7-player-small 6 player-demo -SeaglassWindowSize 960x640
shot mac-8-player-large 6 player-demo -SeaglassWindowSize 1440x900
shot mac-9-lyrics-small 6 player-demo -SeaglassPanel lyrics -SeaglassWindowSize 960x640
shot mac-10-lyrics-large 6 player-demo -SeaglassPanel lyrics -SeaglassWindowSize 1440x900
shot mac-11-queue-small 6 player-demo -SeaglassPanel queue -SeaglassWindowSize 960x640
shot mac-12-queue-large 6 player-demo -SeaglassPanel queue -SeaglassWindowSize 1440x900
shot mac-13-sidebar 6 sidebar-demo
shot mac-14-recognition-listening 4 recognition:listening
shot mac-15-recognition-result 4 recognition:result
# A playlist opened inside the library, a song cued: the player bar must stay over the page.
shot mac-16-library-playlist 8 library-playlist
# The tempo panel on a song made at 124 BPM: its BPM must show (the log says how it was measured).
shot mac-17-tempo 30 tempo-demo -SeaglassPanel tempo
grep "tempo-bpm" "$logs/mac-17-tempo.log" || echo "::warning::The tempo panel said nothing about the BPM"
# The same with a real song streamed (live: YouTube may refuse CI's machines, so a warning only).
shot mac-17b-tempo-live 60 "tempo-live:K0HSD_i2DvA" -SeaglassPanel tempo
grep -e "tempo-bpm" -e "tempo-live" "$logs/mac-17b-tempo-live.log" || true
grep -q "tempo-live: PASS" "$logs/mac-17b-tempo-live.log" || echo "::warning::A streamed song's BPM didn't show (live)"
# The zoom at 130 % from the start, and changed to 150 % with the window open: everything bigger.
shot mac-18-zoom 6 settings -mac.zoom 130
grep "zoom:" "$logs/mac-18-zoom.log" || echo "::warning::The zoom said nothing"
shot mac-18b-zoom-change 8 zoom-change
grep "zoom:" "$logs/mac-18b-zoom-change.log" || echo "::warning::The zoom change said nothing"
# The AirPlay menu opened from the player bar: the whole screen, as the menu is a window of its own.
pkill -x Seaglass 2>/dev/null
NSUnbufferedIO=YES "$binary" -AppleLanguages "(en)" -AppleInterfaceStyle Dark -SeaglassScene airplay >"$logs/airplay.log" 2>&1 &
sleep 8
screencapture -x "$out/mac-19-airplay.png" && echo "Saved mac-19-airplay"
grep -e "airplay:" -e "window:" "$logs/airplay.log"
pkill -x Seaglass 2>/dev/null
shot mac-4-search 12 "search:daft punk"
shot mac-5-settings 6 settings
# The Home with songs listened to (a song's radio, see LaunchScene): recent covers and mixes.
shot mac-6-home-played 20 "home:K0HSD_i2DvA"
pkill -x Seaglass 2>/dev/null

# The app's own volume reaches both fade players without changing the output device.
NSUnbufferedIO=YES "$binary" -SeaglassScene "volume:0.25" >"$logs/volume.log" 2>&1 &
sleep 8
grep "volume: PASS" "$logs/volume.log" || echo "::warning::The app volume check failed"
pkill -x Seaglass 2>/dev/null

exit 0
