#!/usr/bin/env bash
# Measures, with the real network, how long the AAC and Opus paths take to start: see main.swift.
# Usage (from the repository root): bash Tools/OpusStartupProbe/run.sh [videoId ...]
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/onda-opus-startup-probe.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  Onda/Services/JSON.swift Onda/Services/SongDetails.swift Onda/Services/DirectStreams.swift \
  Onda/Services/ChunkedDownload.swift Onda/Services/SharedAudioWork.swift Onda/Services/EnergyPolicy.swift \
  Onda/Services/OpusPipeline.swift Onda/Services/WebMStream.swift Onda/Services/OpusStream.swift \
  Tools/OpusStartupProbe/main.swift -o "$binary"
"$binary" "$@"
