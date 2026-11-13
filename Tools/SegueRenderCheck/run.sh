#!/usr/bin/env bash
# AutoMix's Segue played ahead into a file (Seaglass/Player/Segue/SegueRender.swift), measured on songs
# made here: the file starts and ends on the songs' own samples exactly (so the players hand over
# unheard), the beats stay locked through the window while both tempos glide, the next song's tempo
# comes back to its own gradually (no step), and nothing clicks.
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-segue-render-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Seaglass/Player/AutoMixAnalysis.swift Seaglass/Player/AutoMixPlanner.swift \
  Seaglass/Player/AutoMixFilters.swift Seaglass/Player/AutoMixSelection.swift Seaglass/Player/MixDesign.swift \
  Seaglass/Player/Segue/SeguePlan.swift Seaglass/Player/Segue/SeguePolicy.swift Seaglass/Player/Segue/SegueCompiler.swift \
  Seaglass/Player/Segue/SegueStage.swift Seaglass/Player/Segue/SegueRender.swift Tools/SegueRenderCheck/main.swift -o "$binary"
"$binary"
