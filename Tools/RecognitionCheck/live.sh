#!/usr/bin/env bash
# Manual verification only: downloads a public example, generates a real Apple fingerprint and
# sends ONE honest unauthenticated recognition request. Never run as an automatic build check.
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/seaglass-recognition-live.XXXXXX")
trap 'rm -rf "$work"' EXIT
# AudD publishes this audio as its public recognition example; no AudD API or key is used.
curl --fail --silent --show-error --max-time 30 --max-filesize 10000000 https://audd.tech/example.mp3 -o "$work/example.mp3"
# The public 5.304 s fixture is Everybody Wants To Rule The World by Tears for Fears. Stop before
# recognition if the publisher changes this file, so a fixture change cannot produce a false test.
sample_sha=$(shasum -a 256 "$work/example.mp3" | cut -d ' ' -f 1)
[[ "$sample_sha" == "86544a7dfb3b8486ae648fbcf2a63a843d423d5f602e25b24fbf121f5b86f2b6" ]]
swiftc -O -parse-as-library Seaglass/Models/Track.swift Seaglass/Models/RecognizedSong.swift Seaglass/Services/RecognitionAPI.swift Seaglass/Services/RecognitionSignature.swift Tools/RecognitionCheck/native.swift -o "$work/native"
"$work/native" --live "$work/example.mp3"
