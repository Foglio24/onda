#!/usr/bin/env bash
# Opens Seaglass on an iPhone simulator at each main screen (see Seaglass/App/LaunchScene.swift) and saves
# a screenshot of each, so the UI can be checked without a device. In English (the README shows
# them), with two in Italian. With "ipad", a 13-inch iPad Pro instead (its player also as in landscape).
# Usage: bash Tools/Screenshots/run.sh <Seaglass.app built for the simulator> <output folder> [iphone|ipad]
set -uo pipefail
app="$1"
out="$2"
kind="${3:-iphone}"
mkdir -p "$out"

device=$(xcrun simctl list devices available -j | KIND="$kind" python3 -c '
import json, os, sys
devices = json.load(sys.stdin)["devices"]
every = [d for runtime, list_ in sorted(devices.items()) if "iOS" in runtime for d in list_]
if os.environ["KIND"] == "ipad":
    pads = [d for d in every if d["name"].startswith("iPad")]
    big = [d for d in pads if "Pro" in d["name"] and "13" in d["name"]]
    print((big or pads)[-1]["udid"])
else:
    phones = [d for d in every if d["name"].startswith("iPhone")]
    pro = [d for d in phones if "Pro" in d["name"] and "Max" not in d["name"]]
    print((pro or phones)[-1]["udid"])')
echo "Simulator: $device"
xcrun simctl boot "$device" 2>/dev/null || true
xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl ui "$device" appearance dark
xcrun simctl status_bar "$device" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3 2>/dev/null || true
xcrun simctl install "$device" "$app"

# shot <file name> <language> <seconds to wait> <scene> [more launch arguments]
shot() {
  local name="$1" language="$2" wait="$3" scene="$4"
  shift 4
  xcrun simctl launch --terminate-running-process "$device" com.onda.player \
    -AppleLanguages "($language)" -SeaglassScene "$scene" "$@" >/dev/null
  sleep "$wait"
  xcrun simctl io "$device" screenshot "$out/$name.png" >/dev/null && echo "Saved $name"
}

if [ "$kind" = "recognition" ] || [ "$kind" = "ipad" ]; then
  shot recognition-1-listening en 4 recognition:listening
  shot recognition-2-result en 4 recognition:result
fi
if [ "$kind" = "recognition" ]; then
  xcrun simctl shutdown "$device" || true
  exit 0
fi

if [ "$kind" = "ipad" ]; then
  shot ipad-1-home en 14 home
  shot ipad-2-search en 12 "search:daft punk"
  shot ipad-3-album en 8 "album:MPREb_ePmUY37w4pZ"
  shot ipad-4-library en 5 library
  shot ipad-5-player en 15 "player:K0HSD_i2DvA"
  shot ipad-6-artist en 10 "artist:UCRr1xG_2WIDs18a6cIiCxeA"
  shot ipad-7-settings en 5 settings
  # The player as in landscape, scaled into the portrait screen (see LaunchScene.previewsLandscape).
  shot ipad-8-player-landscape en 15 "player:K0HSD_i2DvA" -SeaglassOrientation landscape
  shot ipad-9-player-queue-landscape en 15 "player:K0HSD_i2DvA" -SeaglassOrientation landscape -SeaglassPanel queue
  xcrun simctl shutdown "$device" || true
  exit 0
fi

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
# The tempo fader, at +4.5 %.
shot 15b-tempo en 15 "player:K0HSD_i2DvA" -SeaglassPanel tempo -playback.tempo 0.045
# The lyrics with the karaoke beside them, as Apple Music's Sing.
shot 15c-sing en 8 player-demo -SeaglassPanel lyrics

# The player card stopped half way between the mini player and the full screen.
xcrun simctl launch --terminate-running-process "$device" com.onda.player \
  -AppleLanguages "(en)" -SeaglassScene "player:K0HSD_i2DvA" -SeaglassCardProgress 0.55 >/dev/null
sleep 12
xcrun simctl io "$device" screenshot "$out/16-player-card.png" >/dev/null && echo "Saved 16-player-card"

# The Mix editor, on two songs it makes itself (YouTube's audio isn't available to CI).
shot 17-mix en 25 mix
shot 18-mix-options en 25 "mix:options"
shot 19-mix-edit en 25 "mix:edit"

# The other languages: Arabic (right to left), Japanese and German (long words).
shot 20-home-arabic ar 10 home
shot 21-player-arabic ar 12 "player:K0HSD_i2DvA"
shot 22-settings-japanese ja 5 settings
shot 23-settings-german de 5 settings

# A system banner ("Ready for Apple Intelligence") can come down over the first ones, a minute or
# so after the simulator starts: these are taken again, long after. (Not Home: by now it shows the
# Mix demo's playlists.)
shot 2-search en 12 "search:daft punk"
shot 3-artist en 10 "artist:UCRr1xG_2WIDs18a6cIiCxeA"

xcrun simctl shutdown "$device" || true
