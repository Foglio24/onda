#!/usr/bin/env bash
# Screenshots of the Android app's main screens on an emulator, to check the UI without a device.
# Usage: screenshots.sh <apk> <output folder>
set -uo pipefail
apk="$1"
out="$2"
pkg=com.onda.seaglass
mkdir -p "$out"

adb install -r -g "$apk"
# The emulator's own apps (the launcher) can stall on CI's software GPU: their "isn't responding"
# dialogs would cover the screenshots. Seaglass's own ANRs and crashes are still saved below.
adb shell settings put global hide_error_dialogs 1
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS > /dev/null 2>&1 || true
sleep 5
adb shell settings put global window_animation_scale 0
adb shell settings put global transition_animation_scale 0
adb shell settings put global animator_duration_scale 0

# Opens the app on a scene (see ui/Launch.kt), waits for it to load, and saves what the screen shows.
# adb joins the arguments into one shell line: values with spaces are quoted twice ("'Daft Punk'").
shot() {
  local name="$1" wait="$2"
  shift 2
  adb shell am start -W -S -n "$pkg/.MainActivity" "$@" > /dev/null
  sleep "$wait"
  adb exec-out screencap -p > "$out/$name.png"
  echo "$name: $(stat -c %s "$out/$name.png") bytes"
}

shot 01-home 20
shot 02-search 15 --es scene search --es query "'Daft Punk'"
shot 03-artist 15 --es scene artist --es query "'Daft Punk'"
shot 04-album 15 --es scene album --es query "'Random Access Memories'"
shot 05-player 25 --es scene player --es query "'Daft Punk Get Lucky'"
shot 06-lyrics 25 --es scene lyrics --es query "'Daft Punk Get Lucky'"
shot 07-library 10 --es scene library
shot 08-settings 8 --es scene settings
shot 08b-settings-audio 8 --es scene settings/audio
shot 08c-settings-playback 8 --es scene settings/playback
shot 08d-equalizer 8 --es scene equalizer --es query rock
shot 09-home-after-listening 20

# The lyrics translated on the phone (an English song into Italian): ML Kit finds its parts and
# downloads the Italian model.
adb shell cmd locale set-app-locales "$pkg" --locales it
shot 06b-lyrics-translated 45 --es scene translate --es query "'Daft Punk Get Lucky'"

# AutoMix: a song into itself from 50 s before its end; the mix is planned from the two ends'
# analyses (decoded on the phone) and made about 20 s before the end.
adb shell cmd locale set-app-locales "$pkg" --locales ""
shot 13-automix-before 25 --es scene automix
sleep 12
adb exec-out screencap -p > "$out/14-automix-mixing.png"
sleep 20
adb shell am start -n "$pkg/.MainActivity" --es scene settings/playback > /dev/null
sleep 5
adb exec-out screencap -p > "$out/15-automix-last.png"
adb logcat -d -s AutoMix:* Transitions:* > "$out/automix-log.txt" || true

# Right to left, and another script.
adb shell cmd locale set-app-locales "$pkg" --locales ar
shot 10-search-arabic 15 --es scene search --es query "Fairuz"
adb shell cmd locale set-app-locales "$pkg" --locales ja
shot 11-player-japanese 25 --es scene player --es query "'YOASOBI Idol'"
adb shell cmd locale set-app-locales "$pkg" --locales ""

# The notification shade with the media controls.
adb shell cmd statusbar expand-notifications
sleep 3
adb exec-out screencap -p > "$out/12-notification.png"
adb shell cmd statusbar collapse

# What went wrong, if anything: the app's ANR and crash reports, and the log.
adb shell dumpsys dropbox --print data_app_anr > "$out/anr.txt" 2>&1 || true
adb shell dumpsys dropbox --print data_app_crash > "$out/crash.txt" 2>&1 || true
adb logcat -d -b main,system,crash '*:I' > "$out/logcat.txt" || true
ls -la "$out"
