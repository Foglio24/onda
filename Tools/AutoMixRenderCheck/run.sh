#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-automix-render-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx14.0" Onda/Player/AutoMixAnalysis.swift Onda/Player/AutoMixPlanner.swift Onda/Player/MixDesign.swift Onda/Player/AutoMixRenderer.swift Onda/Player/AutoMix.swift Tools/AutoMixRenderCheck/main.swift -o "$binary"
"$binary"
