#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-automix-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Onda/Player/AutoMixAnalysis.swift Onda/Player/AutoMixPlanner.swift Tools/AutoMixCheck/main.swift -o "$binary"
"$binary"
