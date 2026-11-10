#!/usr/bin/env bash
# Lossless sources' logic: which candidate is the song (and which is another version of it), how
# a source's files are named in the caches, what is remembered about a song, and the format labels.
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-lossless-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Services/Lossless/LosslessMatch.swift Tools/LosslessCheck/main.swift -o "$binary"
"$binary"
