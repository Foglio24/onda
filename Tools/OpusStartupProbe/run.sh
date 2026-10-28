#!/usr/bin/env bash
# Measures, with the real network, how long the AAC and Opus paths take to start: see main.swift.
# Usage (from the repository root): bash Tools/OpusStartupProbe/run.sh [videoId ...]
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-opus-startup-probe.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  Seaglass/Services/JSON.swift Seaglass/Services/SongDetails.swift Seaglass/Services/DirectStreams.swift \
  Seaglass/Services/ChunkedDownload.swift Seaglass/Services/SharedAudioWork.swift Seaglass/Services/EnergyPolicy.swift \
  Seaglass/Services/OpusPipeline.swift Seaglass/Services/WebMStream.swift Seaglass/Services/OpusStream.swift \
  Tools/OpusStartupProbe/main.swift -o "$binary"
"$binary" "$@"
