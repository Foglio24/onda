#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-live-events-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Services/JSON.swift Seaglass/Services/LiveEvents.swift Tools/LiveEventsCheck/main.swift -o "$binary"
"$binary"
