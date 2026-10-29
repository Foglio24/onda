#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-automix-levels.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx14.0" Seaglass/Player/AutoMixAnalysis.swift Seaglass/Player/AutoMixPlanner.swift Seaglass/Player/AutoMixFilters.swift \
  Seaglass/Player/AutoMixSelection.swift Seaglass/Player/MixDesign.swift Seaglass/Player/AutoMixRenderer.swift Seaglass/Player/AutoMix.swift \
  Seaglass/Player/VocalDetector.swift Seaglass/Player/MDXSeparator.swift Seaglass/Player/EqualizerDSP.swift Tools/AutoMixLevels/Levels.swift Tools/AutoMixLevels/main.swift \
  -o "$binary"
"$binary"
