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
RESOURCE_BUNDLE="$BUILD_DIR/arm64-apple-macosx/release/TokenBar_TokenBar.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    RESOURCE_BUNDLE=$(find "$BUILD_DIR" -type d -name "TokenBar_TokenBar.bundle" -not -path "*.xctest*" | head -1)
fi
if [[ -z "$RESOURCE_BUNDLE" || ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "ERROR: TokenBar_TokenBar.bundle not found; refusing to install an app without provider logos." >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$RESOURCES/"

# License notices travel with the installed binary as well as the source.
cp "$ROOT/LICENSE" "$RESOURCES/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES.md" "$RESOURCES/THIRD_PARTY_NOTICES.md"

# Rewrite Info.plist with exact version/build.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"

echo "=== Codesign ==="
# Sign with a STABLE identity when one is available. Ad-hoc (`--sign -`) mints a
# new signature on every build, which invalidates the Full Disk Access and
# browser-cookie Keychain grants the user approved — the app would need
# re-authorization after every rebuild. A stable identity keeps those grants.
SIGN_IDENTITY="${TOKENBAR_SIGN_IDENTITY:-Apple Development: 1751121595@qq.com (CBDAK7YPZ4)}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
    echo "Signing with: $SIGN_IDENTITY"
    # No silent ad-hoc fallback: an ad-hoc signature changes on every build and
    # silently revokes the Full Disk Access and browser-cookie Keychain grants
    # the user already approved. If the chosen identity fails, stop.
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DST"
else
    echo "No stable identity '$SIGN_IDENTITY' found; signing ad-hoc."
    echo "NOTE: ad-hoc signatures change every build, so Full Disk Access and"
    echo "      browser-cookie Keychain grants must be re-approved after a rebuild."
    echo "TIP: create a codesigning identity and pass TOKENBAR_SIGN_IDENTITY."
    codesign --force --deep --sign - "$APP_DST"
fi

# Gate installation on verification. This used to be `|| true`, so an unsigned
# or broken bundle was installed anyway and then had its quarantine stripped:
# a security failure was reported as success.
echo "=== Verifying signature ==="
codesign --verify --deep --strict "$APP_DST"
codesign -dvv "$APP_DST" 2>&1 | grep -E '^Identifier|^Authority' || echo "Note: no Authority line (ad-hoc signature)."
echo "Bundle: $APP_DST"
ls -la "$APP_DST/Contents/MacOS/"
ls -la "$APP_DST/Contents/Resources/"

# Install to /Applications, only after the bundle verified above.
echo "=== Installing to /Applications ==="
if [[ -d "$APP_PUBLISHED" ]]; then
    echo "Removing existing $APP_PUBLISHED"
    rm -rf "$APP_PUBLISHED"
fi
cp -R "$APP_DST" "$APP_PUBLISHED"

echo "=== Verifying installed copy ==="
codesign --verify --deep --strict "$APP_PUBLISHED"
# Quarantine is cleared only for the copy that just verified.
xattr -dr com.apple.quarantine "$APP_PUBLISHED" 2>/dev/null || true

echo ""
echo "=== Done ==="
echo "Installed: $APP_PUBLISHED"
echo "Version:   $VERSION ($BUILD)"
echo ""
echo "Launch with: open \"$APP_PUBLISHED\""
echo "Or double-click $APP_NAME.app in /Applications."
