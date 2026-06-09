#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_NAME="PingBar"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
MIN_OS_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PROJECT_DIR/Resources/Info.plist")"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

normalize_build_version() {
    local executable="$1"
    local output="$executable.vtool"

    rm -f "$output"
    vtool -set-build-version macos "$MIN_OS_VERSION" "$SDK_VERSION" -output "$output" "$executable"
    chmod +x "$output"
    mv -f "$output" "$executable"
}

cd "$PROJECT_DIR"

echo "Building $APP_NAME..."
swift build -c release

echo "Normalizing build metadata for macOS SDK $SDK_VERSION..."
normalize_build_version "$BUILD_DIR/$APP_NAME"

echo "Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p \
    "$APP_BUNDLE/Contents/MacOS" \
    "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"

echo "Ad hoc signing app..."
codesign --force --options runtime \
    --entitlements "$PROJECT_DIR/Resources/PingBar.entitlements" \
    --sign - \
    "$APP_BUNDLE"

echo "Done! App bundle created at: $APP_BUNDLE"
