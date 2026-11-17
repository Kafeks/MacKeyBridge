#!/bin/bash
<<<<<<< HEAD
# Build MacKeyBridge.app outside the source directory (and never inside Trash).
# Usage: chmod +x build-app.sh && ./build-app.sh
# Optional: BUILD_DIR="$HOME/Applications" SIGN_IDENTITY="MacKeyBridge Dev" ./build-app.sh

set -Eeuo pipefail
=======
# Builds MacKeyBridge.app from main.swift, Clipboard.swift and UI.swift (needs the Xcode command line tools: xcode-select --install).
# Usage:  chmod +x build-app.sh && ./build-app.sh
set -e
>>>>>>> feature/gui
cd "$(dirname "$0")"

APP_NAME="MacKeyBridge.app"
BUILD_DIR="${BUILD_DIR:-$HOME/Applications}"
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd -P)"

<<<<<<< HEAD
case "$BUILD_DIR" in
  "$HOME/.Trash"|"$HOME/.Trash/"*|*/.Trash|*/.Trash/*|*/Trash|*/Trash/*)
    echo "ERROR: Build directory is inside Trash: $BUILD_DIR" >&2
    exit 1
    ;;
esac
=======
swiftc -O main.swift Clipboard.swift UI.swift -o "$APP/Contents/MacOS/MacKeyBridge"
>>>>>>> feature/gui

FINAL_APP="$BUILD_DIR/$APP_NAME"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/.MacKeyBridge-build.XXXXXX")"
STAGED_APP="$STAGING_DIR/$APP_NAME"

cleanup() { rm -rf "$STAGING_DIR"; }
trap cleanup EXIT

mkdir -p "$STAGED_APP/Contents/MacOS"

echo "Compiling..."
swiftc -O main.swift Clipboard.swift UI.swift \
  -o "$STAGED_APP/Contents/MacOS/MacKeyBridge"

cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacKeyBridge</string>
    <key>CFBundleDisplayName</key><string>MacKeyBridge</string>
    <key>CFBundleIdentifier</key><string>local.mackeybridge.client</string>
    <key>CFBundleExecutable</key><string>MacKeyBridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
<<<<<<< HEAD
<<<<<<< HEAD
    <key>CFBundleShortVersionString</key><string>2.1</string>
    <key>CFBundleVersion</key><string>3</string>
=======
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundleVersion</key><string>4</string>
>>>>>>> feature/gui
=======
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundleVersion</key><string>4</string>
>>>>>>> feature/gui
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MacKeyBridge connects to your Windows PC on the local network to send keyboard and trackpad input and to sync the clipboard.</string>
</dict>
</plist>
PLIST

<<<<<<< HEAD
# Ad-hoc signature: gives the app an identity for the macOS privacy permissions. Every rebuild changes it, so after
# rebuilding re-grant Accessibility / Input Monitoring (see README, "Permissions"), or run:
#   tccutil reset Accessibility local.mackeybridge.client; tccutil reset ListenEvent local.mackeybridge.client
# A stable signing identity (see README, "Permissions") keeps the privacy permissions valid across rebuilds:
#   SIGN_IDENTITY="MacKeyBridge Dev" ./build-app.sh
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "Signed ad-hoc: after every rebuild macOS may need the permissions granted again (README -> Permissions)."
fi

echo "Built $APP"
open "$APP"
=======
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" "$STAGED_APP"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP"

# Only replace the installed app after compilation and signing succeed.
if [ -e "$FINAL_APP" ]; then
  rm -rf "$FINAL_APP"
fi
mv "$STAGED_APP" "$FINAL_APP"

echo "Built app at: $FINAL_APP"
echo "Opening this exact path (not a Dock/Trash copy)..."
open -n "$FINAL_APP"
>>>>>>> feature/gui
