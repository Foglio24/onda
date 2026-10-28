#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-startup-metrics-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -parse-as-library Seaglass/Services/PlaybackStartupMetrics.swift Tools/StartupMetricsCheck/main.swift -o "$binary"
"$binary"
