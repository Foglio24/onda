#!/usr/bin/env bash
# Installs the Mac app's release zip over a copy of the app, as its updater does (LaunchScene's
# `update:` scene: the AppKit plug-in unzips it, checks it, puts it in place and reopens it), and
# checks the copy was replaced and opened again on its own. Fails otherwise.
# Usage: bash Tools/MacUpdateCheck/run.sh <Seaglass.app built for Mac> <Seaglass-mac.zip>
set -uo pipefail
app="$1"
zip="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
place=$(mktemp -d)
log="$place/update.log"
ditto "$app" "$place/Seaglass.app"
# Marks the copy: the app put in its place won't have the mark.
xattr -w com.seaglass.check old-copy "$place/Seaglass.app"
"$place/Seaglass.app/Contents/MacOS/Seaglass" -SeaglassScene "update:$zip" >"$log" 2>&1 &
first=$!
for _ in $(seq 1 60); do
  sleep 1
  # Replaced, and running again as another process (the first one quit).
  if ! xattr -p com.seaglass.check "$place/Seaglass.app" >/dev/null 2>&1 \
     && ! kill -0 "$first" 2>/dev/null \
     && pgrep -f "$place/Seaglass.app/Contents/MacOS/Seaglass" >/dev/null; then
    grep "update:" "$log" || true
    echo "The update went in place of the copy, which opened again"
    pkill -f "$place/Seaglass.app/Contents/MacOS/Seaglass"
    exit 0
  fi
done
echo "The update wasn't installed, or the app didn't open again:"
cat "$log" | tail -30
ls -la "$place" "$place/Seaglass.app/Contents"
pkill -f "$place/Seaglass.app/Contents/MacOS/Seaglass"
exit 1
