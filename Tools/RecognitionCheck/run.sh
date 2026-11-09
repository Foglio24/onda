#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/seaglass-recognition-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
sources=(Seaglass/Models/Track.swift Seaglass/Models/RecognizedSong.swift Seaglass/Services/RecognitionAPI.swift)
swiftc -O "${sources[@]}" Tools/RecognitionCheck/main.swift -o "$work/parser"
"$work/parser"
swiftc -O -parse-as-library "${sources[@]}" Seaglass/Services/RecognitionSignature.swift Tools/RecognitionCheck/native.swift -o "$work/native"
"$work/native"
swiftc -O -parse-as-library Seaglass/Services/RecognitionOperation.swift Tools/RecognitionCheck/lifecycle.swift -o "$work/lifecycle"
"$work/lifecycle"
