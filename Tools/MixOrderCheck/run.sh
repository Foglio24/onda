#!/usr/bin/env bash
# "Ordina per il mix" (Seaglass/Player/MixOrder.swift): the features it takes from AutoMix's analysis
# (only what was measured reliably), the Fluido and Energia crescente orders, songs analysed in part or
# not at all, and every song kept.
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-mix-order-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Seaglass/Player/AutoMixAnalysis.swift Seaglass/Player/AutoMixPlanner.swift \
  Seaglass/Player/AutoMixFilters.swift Seaglass/Player/AutoMixSelection.swift Seaglass/Player/MixDesign.swift \
  Seaglass/Player/Segue/SeguePlan.swift Seaglass/Player/Segue/SeguePolicy.swift Seaglass/Player/Segue/SegueCompiler.swift \
  Seaglass/Player/Segue/SegueStage.swift Seaglass/Player/Segue/SegueRender.swift Seaglass/Player/DemoSongs.swift \
  Seaglass/Player/MixOrder.swift Tools/MixOrderCheck/main.swift -o "$binary"
"$binary"
