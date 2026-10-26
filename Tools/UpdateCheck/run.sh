#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-update-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Onda/Services/ReleaseNotes.swift Tools/UpdateCheck/main.swift -o "$binary"
"$binary"
