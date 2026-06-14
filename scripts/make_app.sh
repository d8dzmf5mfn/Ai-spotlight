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

# Copy any *.bundle resources from built SPM products into the app's
# Resources dir. SwiftPM executable targets don't auto-link their
# resource bundles; without this, libraries like KeyboardShortcuts
# crash with "could not find Bundle.module" the moment they try to
# access a localized string. The right place for the bundles is
# Contents/Resources/ (sibling of Contents/MacOS/).
BUNDLE_COUNT=0
for bundle in .build/release/*.bundle; do
    if [ -d "$bundle" ]; then
        cp -R "$bundle" "$APP/Contents/Resources/"
        BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
    fi
done
echo "==> Copied $BUNDLE_COUNT resource bundle(s) into $APP/Contents/Resources/"

# Copy the source Info.plist, then patch the executable path so it's
# guaranteed to match the binary on disk (linker-signed ad-hoc builds
# otherwise get an "Identifier=AISpotlight" mismatch that breaks TCC).
INFO_SRC="Sources/AISpotlight/Resources/Info.plist"
INFO_DEST="$APP/Contents/Info.plist"
cp "$INFO_SRC" "$INFO_DEST"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable AISpotlight" "$INFO_DEST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.aispotlight.app" "$INFO_DEST"
# Force the bundle's Info.plist to be the bound one.
/usr/libexec/PlistBuddy -c "Delete :CFBundleInfoDictionaryVersion" "$INFO_DEST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleInfoDictionaryVersion string 6.0" "$INFO_DEST"

# Ad-hoc sign the *whole* bundle (binary + nested dylibs/frameworks). Without
# --deep and a stable Identifier, macOS treats each build as a new app for
# TCC purposes, which is why ⌘+Space and addGlobalMonitor were silently failing.
codesign --force --deep --sign - "$APP"

echo ""
echo "Built: $APP"
echo "Run:   open '$APP'"
echo "       (right-click → Open the first time to bypass Gatekeeper)"
echo ""
echo "Verify: codesign -dv '$APP'   (Identifier should be com.aispotlight.app)"
