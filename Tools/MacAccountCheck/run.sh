#!/usr/bin/env bash
# Seaglass for Mac signed in to a throwaway account on the live account service, as the sign-in
# sheet leaves it: the session must stay in the Mac's keychain, the account's details must load
# and the library sync, and Settings › Account must show it (a picture of the screen is saved).
# Usage: bash Tools/MacAccountCheck/run.sh <Seaglass.app built for Mac> <picture folder>
set -uo pipefail
cd "$(dirname "$0")/../.."
app="$1"
out="$2"
mkdir -p "$out"
origin=$(/usr/libexec/PlistBuddy -c "Print :SeaglassAccountOrigin" "$app/Contents/Info.plist" 2>/dev/null)
if [ -z "$origin" ]; then
  echo "This build has no account service."
  exit 0
fi
token=$(python3 Tools/MacAccountCheck/session.py "$origin" create) || { echo "Couldn't make a test account on $origin"; exit 1; }
log=$(mktemp)
pkill -x Seaglass 2>/dev/null
NSUnbufferedIO=YES "$app/Contents/MacOS/Seaglass" -AppleLanguages "(en)" -AppleInterfaceStyle Dark \
  -SeaglassScene account -SeaglassAccountToken "$token" >"$log" 2>&1 &
pid=$!
for _ in $(seq 1 45); do
  grep -q -e "account-sync:" -e "account-details: FAIL" "$log" && break
  kill -0 "$pid" 2>/dev/null || break
  sleep 1
done
sleep 2
screencapture -x "$out/mac-16-account.png" && echo "Saved mac-16-account"
kill "$pid" 2>/dev/null
python3 Tools/MacAccountCheck/session.py "$origin" delete "$token" && echo "Test account deleted"
grep "^account-" "$log"
if grep -q "^account-.*FAIL" "$log" || ! grep -q "account-sync: PASS" "$log"; then
  echo "::error::The Mac account check failed"
  tail -40 "$log"
  exit 1
fi
