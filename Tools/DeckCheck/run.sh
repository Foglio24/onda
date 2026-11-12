#!/usr/bin/env bash
# The mix engine's core (Seaglass/Player/Deck): two songs on two decks in one render callback, measured
# on samples: the beats of a song glided to another's tempo landing on that song's beats to a fraction
# of a frame, a deck starting on the exact frame, the lanes' levels, no click through a glide, and the
# same sound whatever the number of frames asked for at once.
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-deck-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -target "$(uname -m)-apple-macosx14.0" Seaglass/Player/AutoMixAnalysis.swift Seaglass/Player/AutoMixPlanner.swift \
  Seaglass/Player/AutoMixFilters.swift Seaglass/Player/AutoMixSelection.swift Seaglass/Player/MixDesign.swift \
  Seaglass/Player/Segue/SeguePlan.swift Seaglass/Player/Segue/SeguePolicy.swift Seaglass/Player/Segue/SegueCompiler.swift \
  Seaglass/Player/Segue/SegueStage.swift Seaglass/Player/Deck/DeckMixer.swift Tools/DeckCheck/main.swift -o "$binary"
"$binary"
