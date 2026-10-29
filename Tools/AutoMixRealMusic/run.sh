#!/usr/bin/env bash
# AutoMix on real songs (see main.swift). Needs the compiled vocal model and the JamendoLyrics
# dataset (JamendoLyrics.csv, mp3/ and annotations/words/). From the repository root:
#   bash Tools/AutoMixRealMusic/run.sh Generated/Karaoke/VocFT.mlmodelc jamendolyrics AutoMix-listening [songs]
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-automix-real.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Seaglass/Player/AutoMixAnalysis.swift Seaglass/Player/AutoMixPlanner.swift \
  Seaglass/Player/AutoMixSelection.swift Seaglass/Player/MixDesign.swift Seaglass/Player/AutoMixRenderer.swift Seaglass/Player/AutoMix.swift \
  Seaglass/Player/VocalDetector.swift Seaglass/Player/MDXSeparator.swift Seaglass/Player/HandoverFade.swift Tools/AutoMixLevels/Levels.swift Tools/AutoMixRealMusic/main.swift -o "$binary"
"$binary" "$@"
