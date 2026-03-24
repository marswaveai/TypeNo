#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$ROOT_DIR/dist/TypeNo.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

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

swift build -c release --package-path "$ROOT_DIR"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BUILD_DIR/TypeNo" "$MACOS_DIR/TypeNo"
cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"

if [ -f "$ROOT_DIR/App/TypeNo.icns" ]; then
    cp "$ROOT_DIR/App/TypeNo.icns" "$RESOURCES_DIR/TypeNo.icns"
fi

chmod +x "$MACOS_DIR/TypeNo"

if command -v codesign >/dev/null 2>&1; then
    CODE_SIGN_NAME="$(find_codesign_identity)"
    if [ -n "$CODE_SIGN_NAME" ]; then
        # Use a stable signing identity when available so macOS permission grants survive rebuilds.
        echo "Signing with: $CODE_SIGN_NAME"
        codesign --force --sign "$CODE_SIGN_NAME" --timestamp=none "$APP_DIR"
    else
        echo "No signing identity found; falling back to ad-hoc signature."
        echo "Accessibility and microphone permissions may need to be re-granted after each rebuild."
        codesign --force --sign - --timestamp=none "$APP_DIR"
    fi
fi

echo "Built $APP_DIR"
