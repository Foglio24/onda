#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-catalog-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Onda/Services/JSON.swift Onda/Models/Track.swift Onda/Services/InnerTube.swift \
  Onda/Services/InnerTube+Catalog.swift Onda/Services/Loudness.swift Onda/Services/SongDetails.swift \
  Tools/CatalogCheck/main.swift -o "$binary"
"$binary"
