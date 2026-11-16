#!/usr/bin/env bash
# Checks how the Spotify account import reads the web player's answers (Seaglass/Services/SpotifyWeb.swift),
# and runs the script it injects into the page (Seaglass/Services/SpotifyHook.swift) against a fake page.
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-spotify-import-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -Onone -target "$(uname -m)-apple-macosx14.0" \
  Seaglass/Models/Track.swift Seaglass/Models/Playlist.swift Seaglass/Models/PlaylistImportReport.swift \
  Seaglass/Services/JSON.swift Seaglass/Services/InnerTube.swift Seaglass/Services/PlaylistImportFile.swift \
  Seaglass/Services/SpotifyWeb.swift Tools/SpotifyImportCheck/main.swift -o "$binary"
"$binary"
node Tools/SpotifyImportCheck/hook.mjs
