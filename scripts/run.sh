#!/usr/bin/env bash
# Build, bundle and run co-sheep in the foreground with logs in this terminal.
#   scripts/run.sh [debug|release]   (default: debug)   CO_SHEEP_DEBUG=1 for verbose logs
set -euo pipefail
cd "$(dirname "$0")/.."
pkill -x CoSheep 2>/dev/null || true
bash scripts/bundle.sh "${1:-debug}"
exec build/co-sheep.app/Contents/MacOS/CoSheep
