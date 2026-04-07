#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
SIGN_IDENTITY="Developer ID Application: RIJO GEORGE (K8383Q54VB)"
APP_NAME="Clack"
echo "==> Building $APP_NAME..."
xcodebuild -project Clack.xcodeproj -scheme Clack -configuration Release clean build CONFIGURATION_BUILD_DIR="$SCRIPT_DIR/build_output" 2>&1
APP_DIR="$SCRIPT_DIR/build_output/$APP_NAME.app"
echo "==> Code signing..."
codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
echo "==> Verifying signature..."
codesign --verify --verbose "$APP_DIR"
echo "Built and signed: $APP_DIR"
