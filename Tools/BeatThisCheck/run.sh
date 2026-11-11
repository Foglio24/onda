#!/usr/bin/env bash
# Beat This! as the app runs it (Seaglass/Player/BeatThis.swift) against upstream's own inference on
# a test signal (Tools/convert_beat_model.py writes the fixture): the log-mel front end, the chunked
# Core ML inference, and the beats and downbeats picked from them.
# Usage: bash Tools/BeatThisCheck/run.sh Generated/BeatThis/BeatThis.mlmodelc Generated/beat-fixture.bin
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-beat-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Seaglass/Player/BeatThis.swift Tools/BeatThisCheck/main.swift -o "$binary"
"$binary" "$@"
