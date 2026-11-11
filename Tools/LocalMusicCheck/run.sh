#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-local-music-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Models/Track.swift Seaglass/Models/LocalMusicIndex.swift Tools/LocalMusicCheck/main.swift -o "$binary"
"$binary"
