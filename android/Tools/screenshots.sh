#!/usr/bin/env bash
# Screenshots of the Android app's main screens on an emulator, to check the UI without a device.
# Usage: screenshots.sh <apk> <output folder>
set -uo pipefail
apk="$1"
out="$2"
pkg=com.onda.seaglass
mkdir -p "$out"

adb install -r -g "$apk"
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0

# Opens the app on a scene (see ui/Launch.kt), waits for it to load, and saves what the screen shows.
shot() {
  local name="$1" wait="$2"
  shift 2
  adb shell am start -W -S -n "$pkg/.MainActivity" "$@" > /dev/null
  sleep "$wait"
  adb exec-out screencap -p > "$out/$name.png"
  echo "$name: $(stat -c %s "$out/$name.png") bytes"
}

shot 01-home 20
shot 02-search 15 --es scene search --es query "Daft Punk"
shot 03-artist 15 --es scene artist --es query "Daft Punk"
shot 04-album 15 --es scene album --es query "Random Access Memories"
shot 05-player 25 --es scene player --es query "Daft Punk Get Lucky"
shot 06-lyrics 25 --es scene lyrics --es query "Daft Punk Get Lucky"
shot 07-library 10 --es scene library
shot 08-settings 8 --es scene settings
shot 09-home-after-listening 20

# Right to left, and another script.
adb shell cmd locale set-app-locales "$pkg" --locales ar
shot 10-search-arabic 15 --es scene search --es query "Fairuz"
adb shell cmd locale set-app-locales "$pkg" --locales ja
shot 11-player-japanese 25 --es scene player --es query "YOASOBI Idol"
adb shell cmd locale set-app-locales "$pkg" --locales ""

# The notification shade with the media controls.
adb shell cmd statusbar expand-notifications
sleep 3
adb exec-out screencap -p > "$out/12-notification.png"
adb shell cmd statusbar collapse

adb logcat -d -t 400 '*:W' > "$out/logcat.txt" || true
ls -la "$out"
