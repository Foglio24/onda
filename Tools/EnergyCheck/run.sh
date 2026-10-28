#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=$(mktemp "${TMPDIR:-/tmp}/onda-energy-check.XXXXXX")
trap 'rm -f "$binary"' EXIT
swiftc -O Seaglass/Services/EnergyPolicy.swift Tools/EnergyCheck/main.swift -o "$binary"
"$binary"
