#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-automix-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Onda/Player/AutoMixAnalysis.swift Onda/Player/AutoMixPlanner.swift \
  Onda/Player/MixDesign.swift Tools/AutoMixCheck/main.swift -o "$binary"
"$binary"
