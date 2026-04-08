#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
CONFIG_PATH="$ROOT_DIR/src-tauri/tauri.conf.json"

PRODUCT_NAME=$(node -e "const c=require(process.argv[1]); process.stdout.write(c.productName);" "$CONFIG_PATH")
VERSION=$(node -e "const c=require(process.argv[1]); process.stdout.write(c.version);" "$CONFIG_PATH")
ARCH=$(uname -m)

APP_PATH="$ROOT_DIR/src-tauri/target/release/bundle/macos/$PRODUCT_NAME.app"
OUT_DIR="$ROOT_DIR/src-tauri/target/release/bundle/dmg"
OUT_DMG="$OUT_DIR/${PRODUCT_NAME}_${VERSION}_${ARCH}.dmg"
STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/$PRODUCT_NAME-dmg.XXXXXX")

cleanup() {
  rm -rf "$STAGE_DIR"
}

trap cleanup EXIT INT TERM

if [ ! -d "$APP_PATH" ]; then
  echo "Missing app bundle at $APP_PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -f "$OUT_DMG"

cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"

hdiutil create \
  -volname "$PRODUCT_NAME" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$OUT_DMG"

echo "Created DMG at $OUT_DMG"
