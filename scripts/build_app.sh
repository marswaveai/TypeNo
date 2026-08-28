#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/TypeNo.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ENTITLEMENTS="$ROOT_DIR/App/TypeNo.entitlements"
ZIP_PATH="$ROOT_DIR/dist/TypeNo.app.zip"

find_codesign_identity() {
    if [ -n "${CODE_SIGN_IDENTITY:-}" ]; then
        printf '%s\n' "$CODE_SIGN_IDENTITY"
        return 0
    fi

    local identities preferred
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"

    preferred="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
    if [ -n "$preferred" ]; then
        printf '%s\n' "$preferred"
        return 0
    fi

    preferred="$(printf '%s\n' "$identities" | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
    if [ -n "$preferred" ]; then
        printf '%s\n' "$preferred"
    fi
}

mkdir -p "$ROOT_DIR/dist"

echo "==> Building TypeNo (Universal Binary: arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64 --package-path "$ROOT_DIR"

UNIVERSAL_BINARY="$ROOT_DIR/.build/apple/Products/Release/TypeNo"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$UNIVERSAL_BINARY" "$MACOS_DIR/TypeNo"

echo "==> Verifying Universal Binary..."
lipo -info "$MACOS_DIR/TypeNo"
cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"

if [ -f "$ROOT_DIR/App/TypeNo.icns" ]; then
    cp "$ROOT_DIR/App/TypeNo.icns" "$RESOURCES_DIR/TypeNo.icns"
fi

chmod +x "$MACOS_DIR/TypeNo"

# Strip Finder/resource-fork metadata that blocks codesigning
xattr -cr "$APP_DIR" 2>/dev/null || true

# --- Code Signing ---
CODE_SIGN_NAME="$(find_codesign_identity)"
if [ -n "$CODE_SIGN_NAME" ]; then
    echo "==> Signing with: $CODE_SIGN_NAME"
    codesign --force --sign "$CODE_SIGN_NAME" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        "$APP_DIR"

    echo "==> Verifying signature..."
    codesign --verify --verbose=2 "$APP_DIR"
    spctl --assess --type execute --verbose=2 "$APP_DIR" 2>&1 || true

    # --- Notarization ---
    echo "==> Creating zip for notarization..."
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

    echo "==> Submitting for notarization..."
    xcrun notarytool submit "$ZIP_PATH" \
        --keychain-profile "notarytool" \
        --wait

    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "$APP_DIR"

    # Re-create zip with stapled ticket
    rm -f "$ZIP_PATH"
    ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

    echo "==> Final verification..."
    spctl --assess --type execute --verbose=2 "$APP_DIR" 2>&1
    echo "==> Done! Signed, notarized, and stapled: $APP_DIR"
    echo "==> Distribution zip: $ZIP_PATH"
else
    echo "No Developer ID signing identity found; falling back to ad-hoc signature."
    echo "Accessibility and microphone permissions may need to be re-granted after each rebuild."
    codesign --force --sign - --timestamp=none "$APP_DIR"
    echo "Built $APP_DIR (ad-hoc signed)"
fi
