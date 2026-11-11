#!/usr/bin/env bash
# AutoMix's live transitions on real songs (see main.swift): the level each pair reaches on the
# analysis' own grid and on Beat This!'s beats. Needs the compiled beat model and the JamendoLyrics
# dataset (JamendoLyrics.csv and mp3/). From the repository root:
#   bash Tools/SegueRealMusic/run.sh Generated/BeatThis/BeatThis.mlmodelc jamendolyrics [songs]
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-segue-real.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Seaglass/Player/AutoMixAnalysis.swift Seaglass/Player/AutoMixPlanner.swift \
  Seaglass/Player/AutoMixFilters.swift Seaglass/Player/AutoMixSelection.swift Seaglass/Player/MixDesign.swift \
  Seaglass/Player/Segue/SeguePlan.swift Seaglass/Player/Segue/SeguePolicy.swift Seaglass/Player/Segue/SegueCompiler.swift \
  Seaglass/Player/BeatThis.swift Tools/SegueRealMusic/main.swift -o "$binary"
"$binary" "$@"
