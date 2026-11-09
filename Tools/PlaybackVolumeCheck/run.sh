#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-playback-volume-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -parse-as-library Seaglass/Player/PlaybackVolume.swift Tools/PlaybackVolumeCheck/main.swift -o "$binary"
"$binary"
