#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-playlist-import-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" \
  Seaglass/Models/Track.swift Seaglass/Models/Playlist.swift Seaglass/Models/PlaylistImportReport.swift \
  Seaglass/Services/JSON.swift Seaglass/Services/InnerTube.swift Seaglass/Services/PlaylistImportFile.swift \
  Tools/PlaylistImportCheck/main.swift -o "$binary"
"$binary"
