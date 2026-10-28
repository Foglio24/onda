#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-equalizer-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Player/EqualizerDSP.swift Tools/EqualizerCheck/main.swift -o "$binary"
"$binary"
