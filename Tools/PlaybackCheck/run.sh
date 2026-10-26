#!/usr/bin/env bash
set -euo pipefail
binary="$(mktemp "${TMPDIR:-/tmp}/onda-playback-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -parse-as-library Onda/Player/PlaybackState.swift Tools/PlaybackCheck/main.swift -o "$binary"
"$binary"
