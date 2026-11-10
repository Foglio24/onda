#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary="$(mktemp "${TMPDIR:-/tmp}/seaglass-account-sync-check.XXXXXX")"
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Models/Track.swift Seaglass/Services/LibrarySync.swift Tools/AccountSyncCheck/main.swift -o "$binary"
"$binary"
