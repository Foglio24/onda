#!/usr/bin/env bash
set -euo pipefail
binary="$(mktemp "${TMPDIR:-/tmp}/onda-audio-work-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -parse-as-library Onda/Services/SharedAudioWork.swift Tools/AudioWorkCheck/main.swift -o "$binary"
"$binary"
