#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"
APP_NAME="Clack"
DMG_NAME="Clack"
VERSION="1.0.0"
DMG_FINAL="$SCRIPT_DIR/$DMG_NAME-$VERSION.dmg"
DMG_TEMP="$SCRIPT_DIR/_dmg_temp.dmg"
STAGING="$SCRIPT_DIR/_dmg_staging"
SIGN_IDENTITY="Developer ID Application: RIJO GEORGE (K8383Q54VB)"
TEAM_ID="K8383Q54VB"
echo "==> Building and signing app..."
bash build-app.sh
echo "==> Preparing DMG staging..."
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$SCRIPT_DIR/build_output/$APP_NAME.app" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
mkdir -p "$STAGING/.background"
SIZE_KB=$(du -sk "$STAGING" | awk '{print $1}')
SIZE_KB=$((SIZE_KB + 10240))
echo "==> Creating DMG..."
rm -f "$DMG_TEMP" "$DMG_FINAL"
hdiutil create -srcfolder "$STAGING" -volname "$APP_NAME" -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW -size ${SIZE_KB}k "$DMG_TEMP"
MOUNT_DIR=$(hdiutil attach -readwrite -noverify -noautoopen "$DMG_TEMP" | grep "/Volumes/" | awk -F'\t' '{print $NF}')
echo "==> Configuring DMG layout..."
osascript << APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 120, 800, 520}
        set theViewOptions to icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 80
        set position of item "$APP_NAME.app" of container window to {150, 180}
        set position of item "Applications" of container window to {450, 180}
        close
        open
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
sync
hdiutil detach "$MOUNT_DIR"
echo "==> Compressing DMG..."
hdiutil convert "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_FINAL"
rm -rf "$STAGING" "$DMG_TEMP"
echo "==> Signing DMG..."
codesign --force --sign "$SIGN_IDENTITY" "$DMG_FINAL"
echo "==> Submitting for notarization..."
xcrun notarytool submit "$DMG_FINAL" --keychain-profile "notary" --wait 2>&1
echo "==> Stapling notarization ticket..."
xcrun stapler staple "$DMG_FINAL"
echo "DMG created, signed, and notarized: $DMG_FINAL"
