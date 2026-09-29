#!/usr/bin/env bash
# Package build/co-sheep.app into build/co-sheep_<version>_<arch>.dmg.
#   scripts/build-dmg.sh          (builds a release bundle first)
set -euo pipefail
cd "$(dirname "$0")/.."

bash scripts/bundle.sh release

APP="build/co-sheep.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
ARCH=$(uname -m)
OUT_DMG="build/co-sheep_${VERSION}_${ARCH}.dmg"
STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/co-sheep-dmg.XXXXXX")
trap 'rm -rf "$STAGE_DIR"' EXIT INT TERM

cp -R "$APP" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
rm -f "$OUT_DMG"

hdiutil create \
  -volname "co-sheep" \
  -srcfolder "$STAGE_DIR" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$OUT_DMG"

echo "Created DMG at $OUT_DMG"
