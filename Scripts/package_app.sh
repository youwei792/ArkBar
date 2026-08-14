#!/usr/bin/env bash
# Build TokenBar as a signed .app bundle and install it to /Applications.
# Usage: ./Scripts/package_app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="TokenBar"
BUNDLE_ID="com.wwwsidequest.tokenbar"
VERSION="0.1.0"
BUILD="1"

BUILD_DIR="$ROOT/.build"
APP_DST="$ROOT/$APP_NAME.app"
APP_PUBLISHED="/Applications/$APP_NAME.app"

echo "=== Building release binary for arm64 ==="
swift build -c release --arch arm64 2>&1 | tail -3

BIN="$BUILD_DIR/release/$APP_NAME"
if [[ ! -x "$BIN" ]]; then
    echo "ERROR: release binary not found at $BIN" >&2
    exit 1
fi

echo "=== Assembling $APP_NAME.app bundle ==="
# Clean any prior bundle.
[[ -d "$APP_DST" ]] && rm -rf "$APP_DST"

CONTENTS="$APP_DST/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RESOURCES"

# Executable.
cp "$BIN" "$MACOS/$APP_NAME"
chmod +x "$MACOS/$APP_NAME"

# Info.plist.
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"

# Icon.
cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"

# SwiftPM resource bundle (provider logos). swift build places it under .build/
# with the package's module name; copy it into the app so Bundle.module stays
# resolvable from the installed bundle.
RESOURCE_BUNDLE=$(find "$BUILD_DIR" -name "TokenBar_TokenBar.bundle" -maxdepth 4 2>/dev/null | head -1)
if [[ -n "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$RESOURCES/"
else
    echo "WARN: TokenBar_TokenBar.bundle not found; provider logos will be missing." >&2
fi

# License notices travel with the installed binary as well as the source.
cp "$ROOT/LICENSE" "$RESOURCES/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"

# Rewrite Info.plist with exact version/build.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"

echo "=== Ad-hoc codesign ==="
# Remove any pre-existing signature, then sign ad-hoc with the current identity.
codesign --force --deep --sign - "$APP_DST" 2>&1 || {
    echo "WARN: codesign failed; bundle will still run but may trigger Gatekeeper on first launch." >&2
}

echo "=== Verifying bundle ==="
codesign --verify --deep --strict "$APP_DST" 2>&1 || true
echo "Bundle: $APP_DST"
ls -la "$APP_DST/Contents/MacOS/"
ls -la "$APP_DST/Contents/Resources/"

# Install to /Applications.
echo "=== Installing to /Applications ==="
if [[ -d "$APP_PUBLISHED" ]]; then
    echo "Removing existing $APP_PUBLISHED"
    rm -rf "$APP_PUBLISHED"
fi
cp -R "$APP_DST" "$APP_PUBLISHED"
xattr -dr com.apple.quarantine "$APP_PUBLISHED" 2>/dev/null || true

echo ""
echo "=== Done ==="
echo "Installed: $APP_PUBLISHED"
echo "Version:   $VERSION ($BUILD)"
echo ""
echo "Launch with: open \"$APP_PUBLISHED\""
echo "Or double-click $APP_NAME.app in /Applications."
