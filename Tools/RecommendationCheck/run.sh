#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-recommendation-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Onda/Models/Track.swift Onda/Services/Recommender.swift Tools/RecommendationCheck/main.swift -o "$binary"
"$binary"
