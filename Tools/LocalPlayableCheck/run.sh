#!/usr/bin/env bash
# The way in for the user's own songs that AVPlayer won't open (Seaglass/Services/LocalPlayable): files
# decoded by the app into PCM copies, checked on samples. Run from the repository root.
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-local-playable-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Seaglass/Services/LocalPlayable.swift Tools/LocalPlayableCheck/main.swift -o "$binary"
"$binary"
