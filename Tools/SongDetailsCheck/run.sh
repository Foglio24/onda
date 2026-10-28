#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-song-details-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Services/JSON.swift Seaglass/Services/SongDetails.swift Tools/SongDetailsCheck/main.swift -o "$binary"
"$binary"
