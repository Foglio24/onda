#!/usr/bin/env bash
# Opens Seaglass on an iPhone simulator at each main screen (see Seaglass/App/LaunchScene.swift) and saves
# a screenshot of each, so the UI can be checked without a device. In English (the README shows
# them), with two in Italian.
# Usage: bash Tools/Screenshots/run.sh <Seaglass.app built for the simulator> <output folder>
set -uo pipefail
app="$1"
out="$2"
mkdir -p "$out"

device=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
phones = [d for runtime, list_ in sorted(devices.items()) if "iOS" in runtime for d in list_
          if d["name"].startswith("iPhone")]
pro = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]]
print((pro or phones)[-1]["udid"])')
echo "Simulator: $device"
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl ui "$device" appearance dark
xcrun simctl status_bar "$device" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 2>/dev/null || true
xcrun simctl install "$device" "$app"

# shot <file name> <language> <seconds to wait> <scene>
shot() {
  xcrun simctl launch --terminate-running-process "$device" com.onda.player \
    -AppleLanguages "($2)" -SeaglassScene "$4" >/dev/null
  sleep "$3"
  xcrun simctl io "$device" screenshot "$out/$1.png" >/dev/null && echo "Saved $1"
}

shot 1-home en 14 home
shot 2-search en 12 "search:daft punk"
shot 3-artist en 10 "artist:UCRr1xG_2WIDs18a6cIiCxeA"
shot 4-album en 8 "album:MPREb_ePmUY37w4pZ"
shot 5-library en 5 library
shot 6-settings en 5 settings
shot 7-player en 15 "player:K0HSD_i2DvA"
shot 8-home-italian it 10 home

# Downloads: six songs start downloading, seen once while they run and again later in the same launch.
shot 9-downloading en 9 "downloads:K0HSD_i2DvA"
sleep 30
xcrun simctl io "$device" screenshot "$out/10-downloaded.png" >/dev/null && echo "Saved 10-downloaded"
shot 11-storage en 6 storage
shot 12-album-downloads en 8 "album:MPREb_ePmUY37w4pZ"

shot 13-song-info en 14 "info:MPREb_ePmUY37w4pZ"
shot 14-equalizer en 6 equalizer
shot 15-song-info-italian it 14 "info:MPREb_ePmUY37w4pZ"

# The player card stopped half way between the mini player and the full screen.
xcrun simctl launch --terminate-running-process "$device" com.onda.player \
  -AppleLanguages "(en)" -SeaglassScene "player:K0HSD_i2DvA" -SeaglassCardProgress 0.55 >/dev/null
sleep 12
xcrun simctl io "$device" screenshot "$out/16-player-card.png" >/dev/null && echo "Saved 16-player-card"

# The Mix editor, on two songs it makes itself (YouTube's audio isn't available to CI).
shot 17-mix en 25 mix
shot 18-mix-options en 25 "mix:options"
shot 19-mix-edit en 25 "mix:edit"

xcrun simctl shutdown "$device" || true
