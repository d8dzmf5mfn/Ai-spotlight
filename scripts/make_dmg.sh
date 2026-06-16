#!/bin/bash
# Generate AI Spotlight .dmg installer
set -euo pipefail

APP_NAME="AI Spotlight"
APP_BUNDLE="build/${APP_NAME}.app"
DMG_NAME="AI-Spotlight-Installer.dmg"
STAGING_DIR="/tmp/aispotlight-dmg-staging"

# Build if needed
if [ ! -d "$APP_BUNDLE" ]; then
    echo "Building app..."
    cd "$(dirname "$0")/.." || exit 1
    swift build -c release
    ./scripts/make_app.sh
fi

cd "$(dirname "$0")/.."
SRC_DIR="$PWD"

echo "Creating DMG from ${APP_BUNDLE}..."

# Clean staging
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy app bundle
cp -R "$APP_BUNDLE" "$STAGING_DIR/${APP_NAME}.app"

# Create Applications symlink
ln -s /Applications "$STAGING_DIR/Applications"

# Remove old DMG if exists
rm -f "$DMG_NAME"

# Create the DMG
hdiutil create \
    -volname "AI Spotlight" \
    -srcfolder "$STAGING_DIR" \
    -ov -format UDZO \
    -size 200m \
    "$DMG_NAME" 2>&1 | tail -3

# Clean staging
rm -rf "$STAGING_DIR"

# Move to build/ for gitignored safety
mv "$DMG_NAME" "build/${DMG_NAME}" 2>/dev/null || true

echo "✅ DMG created: build/${DMG_NAME}"
echo "Size: $(du -h "build/${DMG_NAME}" | cut -f1)"
