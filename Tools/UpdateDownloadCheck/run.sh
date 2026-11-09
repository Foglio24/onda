#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d "${TMPDIR:-/tmp}/seaglass-update-download-check.XXXXXX")
fixture_pid=""
cleanup() {
  if [[ -n "$fixture_pid" ]]; then kill "$fixture_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
swiftc -O -parse-as-library Seaglass/Services/UpdateDownload.swift Tools/UpdateDownloadCheck/main.swift -o "$work/check"
python3 Tools/UpdateDownloadCheck/fixture.py "$work/port" &
fixture_pid=$!
for _ in $(seq 1 50); do
  [[ -s "$work/port" ]] && break
  sleep 0.1
done
[[ -s "$work/port" ]]
"$work/check" "http://127.0.0.1:$(cat "$work/port")/release.zip"
