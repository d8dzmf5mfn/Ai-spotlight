#!/usr/bin/env bash
# Build AI Spotlight as a .app bundle for personal use.
# Output: build/AI Spotlight.app
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Building release binary"
swift build -c release

APP="build/AI Spotlight.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AISpotlight "$APP/Contents/MacOS/AISpotlight"
cp Sources/AISpotlight/Resources/Info.plist "$APP/Contents/Info.plist"

echo ""
echo "Built: $APP"
echo "Run:   open '$APP'"
echo "       (right-click → Open the first time to bypass Gatekeeper)"
