#!/bin/sh
# Builds nsbench in release and runs it. The table goes to the terminal (stderr), the JSON to
# build/bench/. Usage: scripts/bench.sh [--quick]   (--quick is a smoke test, not a result)
set -e
cd "$(dirname "$0")/.."
swift build -c release --product nsbench
BIN="$(swift build -c release --product nsbench --show-bin-path)/nsbench"
mkdir -p build/bench
OUT="build/bench/nsbench-$(date -u +%Y%m%dT%H%M%SZ).json"
"$BIN" --json "$@" > "$OUT"
echo "JSON: $OUT"
