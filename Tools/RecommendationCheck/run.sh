#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-recommendation-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Models/Track.swift Seaglass/Services/Recommender.swift Tools/RecommendationCheck/main.swift -o "$binary"
"$binary"
