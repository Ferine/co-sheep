#!/bin/sh
set -eu

if [ "${1:-}" != "build" ]; then
  exec tauri "$@"
fi

shift

HAS_BUNDLES=0
for arg in "$@"; do
  if [ "$arg" = "--bundles" ]; then
    HAS_BUNDLES=1
    break
  fi
done

if [ "$HAS_BUNDLES" -eq 1 ]; then
  exec tauri build "$@"
fi

tauri build "$@"
pnpm run bundle:dmg
