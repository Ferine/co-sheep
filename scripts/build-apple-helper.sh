#!/bin/sh
# Compiles the Apple Intelligence sidecar (src-tauri/helper/apple-ai-helper.swift)
# into src-tauri/binaries/ with the target-triple suffix Tauri expects for
# externalBin. Runs as part of `npm run build:tauri` and `npm run dev`.
#
# The helper compiles with any recent Xcode; the on-device model itself needs
# the macOS 26 SDK (Xcode 26+) — older toolchains produce a helper that
# reports Apple Intelligence as unavailable instead of failing the build.
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
  echo "[build-apple-helper] Not macOS — skipping Apple Intelligence helper build"
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "[build-apple-helper] swiftc not found — install Xcode command line tools" >&2
  exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

ARCH=$(uname -m)
case "$ARCH" in
  arm64) TRIPLE="aarch64-apple-darwin" ;;
  x86_64) TRIPLE="x86_64-apple-darwin" ;;
  *)
    echo "[build-apple-helper] Unsupported architecture: $ARCH" >&2
    exit 1
    ;;
esac

OUT_DIR="$ROOT_DIR/src-tauri/binaries"
OUT_BIN="$OUT_DIR/apple-ai-helper-$TRIPLE"
SRC="$ROOT_DIR/src-tauri/helper/apple-ai-helper.swift"

mkdir -p "$OUT_DIR"

swiftc -parse-as-library -O -o "$OUT_BIN" "$SRC"

echo "[build-apple-helper] Built $OUT_BIN"
