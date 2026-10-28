#!/usr/bin/env bash
set -euo pipefail

check_binary="$(mktemp -t onda-scrobble-check.XXXXXX)"
trap 'rm -f "$check_binary"' EXIT
swiftc -O Seaglass/Services/ScrobbleOutbox.swift Tools/ScrobbleCheck/main.swift -o "$check_binary"
"$check_binary"
