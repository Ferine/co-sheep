#!/usr/bin/env bash
# Assemble build/co-sheep.app from the SwiftPM build.
#   scripts/bundle.sh [debug|release]      (default: release)
# Signing: $CODESIGN_IDENTITY, else a "co-sheep dev" identity if present
# (stable signature → macOS keeps the Screen Recording grant across
# rebuilds), else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/co-sheep.app"
VERSION="0.1.0"

swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/CoSheep" "$APP/Contents/MacOS/CoSheep"
cp -R "$BIN_DIR/co-sheep_CoSheepKit.bundle" "$APP/Contents/Resources/"
cp Sources/CoSheepKit/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.cosheep.app</string>
  <key>CFBundleName</key><string>co-sheep</string>
  <key>CFBundleDisplayName</key><string>co-sheep</string>
  <key>CFBundleExecutable</key><string>CoSheep</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>27.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "co-sheep dev"; then
  IDENTITY="co-sheep dev"
fi
IDENTITY="${IDENTITY:--}"
codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null
echo "Built $APP ($CONFIG, signed: $IDENTITY)"
