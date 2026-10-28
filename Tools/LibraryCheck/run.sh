#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-library-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Models/Track.swift Tools/LibraryCheck/main.swift -o "$binary"
"$binary"
