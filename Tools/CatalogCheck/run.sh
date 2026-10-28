#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-catalog-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Services/JSON.swift Seaglass/Models/Track.swift Seaglass/Services/InnerTube.swift \
  Seaglass/Services/InnerTube+Catalog.swift Seaglass/Services/Loudness.swift Seaglass/Services/SongDetails.swift \
  Seaglass/Services/DirectStreams.swift Tools/CatalogCheck/main.swift -o "$binary"
"$binary"
