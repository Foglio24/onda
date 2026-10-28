#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-stream-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Services/JSON.swift Seaglass/Services/SongDetails.swift Seaglass/Services/DirectStreams.swift \
  Tools/StreamCheck/main.swift -o "$binary"
"$binary"
