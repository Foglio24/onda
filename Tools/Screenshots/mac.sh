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
shot mac-7-player-small 16 "player:K0HSD_i2DvA" -SeaglassWindowSize 960x640
shot mac-8-player-large 16 "player:K0HSD_i2DvA" -SeaglassWindowSize 1440x900
shot mac-9-lyrics-small 16 "player:K0HSD_i2DvA" -SeaglassPanel lyrics -SeaglassWindowSize 960x640
shot mac-10-lyrics-large 16 "player:K0HSD_i2DvA" -SeaglassPanel lyrics -SeaglassWindowSize 1440x900
shot mac-11-queue-small 16 "player:K0HSD_i2DvA" -SeaglassPanel queue -SeaglassWindowSize 960x640
shot mac-12-queue-large 16 "player:K0HSD_i2DvA" -SeaglassPanel queue -SeaglassWindowSize 1440x900
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
