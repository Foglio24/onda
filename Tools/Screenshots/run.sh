#!/usr/bin/env bash
# Opens Onda on an iPhone simulator at each main screen (see Onda/App/LaunchScene.swift) and saves
# a screenshot of each, so the UI can be checked without a device.
# Usage: bash Tools/Screenshots/run.sh <Onda.app built for the simulator> <output folder>
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
    -AppleLanguages "($2)" -OndaScene "$4" >/dev/null
  sleep "$3"
  xcrun simctl io "$device" screenshot "$out/$1.png" >/dev/null && echo "Saved $1"
}

shot 1-home it 14 home
shot 2-search it 12 "search:daft punk"
shot 3-artist it 10 "artist:UCRr1xG_2WIDs18a6cIiCxeA"
shot 4-album it 8 "album:MPREb_ePmUY37w4pZ"
shot 5-library it 5 library
shot 6-settings it 5 settings
shot 7-player it 15 "player:K0HSD_i2DvA"
shot 8-home-english en 10 home

# Downloads: six songs start downloading, seen once while they run and again later in the same launch.
shot 9-downloading it 9 "downloads:K0HSD_i2DvA"
sleep 30
xcrun simctl io "$device" screenshot "$out/10-downloaded.png" >/dev/null && echo "Saved 10-downloaded"
shot 11-storage it 6 storage
shot 12-album-downloads it 8 "album:MPREb_ePmUY37w4pZ"

shot 13-song-info it 14 "info:MPREb_ePmUY37w4pZ"
shot 14-equalizer it 6 equalizer
shot 15-song-info-english en 14 "info:MPREb_ePmUY37w4pZ"

# The player card stopped half way between the mini player and the full screen.
xcrun simctl launch --terminate-running-process "$device" com.onda.player \
  -AppleLanguages "(it)" -OndaScene "player:K0HSD_i2DvA" -OndaCardProgress 0.55 >/dev/null
sleep 12
xcrun simctl io "$device" screenshot "$out/16-player-card.png" >/dev/null && echo "Saved 16-player-card"

# The Mix editor, on two songs it makes itself (YouTube's audio isn't available to CI).
shot 17-mix it 25 mix
shot 18-mix-options it 25 "mix:options"
shot 19-mix-edit it 25 "mix:edit"

xcrun simctl shutdown "$device" || true
