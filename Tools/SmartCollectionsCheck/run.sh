#!/usr/bin/env bash
# The library's smart collections (Seaglass/Services/SmartCollections.swift): each rule on the data the app
# keeps (the history, the downloads, the favourites, the listening log), an empty library included.
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-smart-collections-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Models/Track.swift Seaglass/Services/Recommender.swift Seaglass/Services/SmartCollections.swift Seaglass/Services/MonthlyRecap.swift \
  Tools/SmartCollectionsCheck/main.swift -o "$binary"
"$binary"
