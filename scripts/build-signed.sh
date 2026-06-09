#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build/release"
APP_NAME="PingBar"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
MIN_OS_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$PROJECT_DIR/Resources/Info.plist")"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"

DEVELOPER_ID="Developer ID Application: Johan Eliasson (J2Z78W23W7)"
TEAM_ID="J2Z78W23W7"
BUNDLE_ID="com.elitan.pingbar"

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

echo "Signing app with hardened runtime..."
codesign --force --options runtime \
    --entitlements "$PROJECT_DIR/Resources/PingBar.entitlements" \
    --sign "$DEVELOPER_ID" \
    --timestamp \
    "$APP_BUNDLE"

echo "Verifying signature..."
codesign --verify --verbose "$APP_BUNDLE"

echo "Creating ZIP for notarization..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo ""
echo "====================================="
echo "App signed successfully!"
echo "ZIP ready for notarization: $ZIP_PATH"
echo ""
echo "To notarize, run:"
echo "  xcrun notarytool submit $ZIP_PATH --apple-id YOUR_APPLE_ID --password YOUR_APP_SPECIFIC_PASSWORD --team-id $TEAM_ID --wait"
echo ""
echo "After notarization succeeds, staple with:"
echo "  xcrun stapler staple $APP_BUNDLE"
echo "====================================="
