#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
APP_NAME="Spool"
BUNDLE_ID="com.fieldgrid.spool"

echo "=== Building $APP_NAME ==="

swift build -c release
BINARY_PATH=".build/release/$APP_NAME"

if [[ ! -f "$BINARY_PATH" ]]; then
  echo "Build failed: binary not found at $BINARY_PATH"
  exit 1
fi

APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Sources/Spool/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT_DIR/Sources/Spool/Assets/AppIcon.icns" ]]; then
  cp "$ROOT_DIR/Sources/Spool/Assets/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "App bundle created: $APP_DIR"
echo "Bundle identifier: $BUNDLE_ID"

rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
echo "Installed to /Applications/$APP_NAME.app"

echo "=== Build complete ==="
