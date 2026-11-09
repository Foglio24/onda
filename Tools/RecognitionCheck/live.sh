#!/usr/bin/env bash
# Manual verification only: downloads a public example, generates a real Apple fingerprint and
# sends ONE honest unauthenticated recognition request. Never run as an automatic build check.
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/seaglass-recognition-live.XXXXXX")
trap 'rm -rf "$work"' EXIT
# AudD publishes this audio as its public recognition example; no AudD API or key is used.
curl --fail --silent --show-error --max-time 30 https://audd.tech/example.mp3 -o "$work/example.mp3"
swiftc -O -parse-as-library Seaglass/Models/Track.swift Seaglass/Models/RecognizedSong.swift Seaglass/Services/RecognitionAPI.swift Seaglass/Services/RecognitionSignature.swift Tools/RecognitionCheck/native.swift -o "$work/native"
"$work/native" --live "$work/example.mp3"
