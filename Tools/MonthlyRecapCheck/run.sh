#!/usr/bin/env bash
# The monthly recap (Seaglass/Services/MonthlyRecap.swift): what counts as a listen, plays joined when a
# song was taken up again, the month's figures, the period the data cover and months with few listens.
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-monthly-recap-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Models/Track.swift Seaglass/Services/Recommender.swift Seaglass/Services/MonthlyRecap.swift \
  Tools/MonthlyRecapCheck/main.swift -o "$binary"
"$binary"
