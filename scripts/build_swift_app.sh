#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$(pwd)"
APP_NAME="Spool"
BUNDLE_ID="com.fieldgrid.spool"
ENV_FILE="$ROOT_DIR/.env"

echo "=== Building $APP_NAME ==="

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

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

if [[ -n "${GOOGLE_CALENDAR_CLIENT_ID:-}" && -n "${GOOGLE_CALENDAR_CLIENT_SECRET:-}" ]]; then
  cat > "$APP_DIR/Contents/Resources/GoogleOAuthConfig.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>GOOGLE_CALENDAR_CLIENT_ID</key>
  <string>${GOOGLE_CALENDAR_CLIENT_ID}</string>
  <key>GOOGLE_CALENDAR_CLIENT_SECRET</key>
  <string>${GOOGLE_CALENDAR_CLIENT_SECRET}</string>
</dict>
</plist>
EOF
  echo "Bundled Google OAuth config from .env"
else
  echo "Skipping Google OAuth bundle config; GOOGLE_CALENDAR_CLIENT_ID/SECRET not set"
fi

echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

echo "App bundle created: $APP_DIR"
echo "Bundle identifier: $BUNDLE_ID"

rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
echo "Installed to /Applications/$APP_NAME.app"

echo "=== Build complete ==="
