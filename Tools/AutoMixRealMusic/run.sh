#!/usr/bin/env bash
# AutoMix on real songs (see main.swift). Needs the compiled vocal model and the JamendoLyrics
# dataset (JamendoLyrics.csv, mp3/ and annotations/words/). From the repository root:
#   bash Tools/AutoMixRealMusic/run.sh Generated/Karaoke/VocFT.mlmodelc jamendolyrics AutoMix-listening [songs]
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-automix-real.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Onda/Player/AutoMixAnalysis.swift Onda/Player/AutoMixPlanner.swift \
  Onda/Player/AutoMixSelection.swift Onda/Player/MixDesign.swift Onda/Player/AutoMixRenderer.swift Onda/Player/AutoMix.swift \
  Onda/Player/VocalDetector.swift Onda/Player/MDXSeparator.swift Tools/AutoMixRealMusic/main.swift -o "$binary"
"$binary" "$@"
