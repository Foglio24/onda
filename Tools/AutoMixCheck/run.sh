#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-automix-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Seaglass/Player/AutoMixAnalysis.swift Seaglass/Player/AutoMixPlanner.swift Seaglass/Player/AutoMixFilters.swift Seaglass/Player/AutoMixSelection.swift \
  Seaglass/Player/MixDesign.swift Tools/AutoMixCheck/main.swift -o "$binary"
"$binary"
