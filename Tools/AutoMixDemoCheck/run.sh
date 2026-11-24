#!/usr/bin/env bash
# The Home's AutoMix demo (Seaglass/Player/DemoSongs.swift, Seaglass/Player/TransitionClip.swift), on its
# own two songs as the app makes them: AutoMix mixes them, both listens follow on without a jump where
# one piece meets the next, and they are as loud as each other (only the passage differs).
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-automix-demo-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Seaglass/Player/AutoMixAnalysis.swift Seaglass/Player/AutoMixPlanner.swift \
  Seaglass/Player/AutoMixFilters.swift Seaglass/Player/AutoMixSelection.swift Seaglass/Player/MixDesign.swift \
  Seaglass/Player/Segue/SeguePlan.swift Seaglass/Player/Segue/SeguePolicy.swift Seaglass/Player/Segue/SegueCompiler.swift \
  Seaglass/Player/Segue/SegueStage.swift Seaglass/Player/Segue/SegueRender.swift Seaglass/Player/DemoSongs.swift \
  Seaglass/Player/TransitionClip.swift Tools/AutoMixDemoCheck/main.swift -o "$binary"
"$binary"
