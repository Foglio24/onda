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

# shot <file name> <seconds to wait> <scene> [more launch arguments]
shot() {
  local name="$1" wait="$2" scene="$3"
  shift 3
  pkill -x Seaglass 2>/dev/null
  sleep 1
  "$binary" -AppleLanguages "(en)" -AppleInterfaceStyle Dark -SeaglassScene "$scene" "$@" >/dev/null 2>&1 &
  sleep "$wait"
  local window=""
  [ -x "$tools/window" ] && window=$("$tools/window")
  if [ -n "$window" ]; then
    screencapture -x -o -l"$window" "$out/$name.png" && echo "Saved $name (window $window)"
  else
    screencapture -x "$out/$name.png" && echo "Saved $name (whole screen: no window found)"
  fi
}

shot mac-1-home 16 home
shot mac-2-player 16 "player:K0HSD_i2DvA"
shot mac-3-player-queue 16 "player:K0HSD_i2DvA" -SeaglassPanel queue
shot mac-4-search 12 "search:daft punk"
shot mac-5-settings 6 settings
pkill -x Seaglass 2>/dev/null
exit 0
