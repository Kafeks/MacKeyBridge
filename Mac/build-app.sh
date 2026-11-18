#!/bin/bash
# Builds MacKeyBridge.app from main.swift, Clipboard.swift and UI.swift (needs the Xcode command line tools: xcode-select --install).
# Usage:  chmod +x build-app.sh && ./build-app.sh
set -e
cd "$(dirname "$0")"

APP="MacKeyBridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O main.swift Clipboard.swift UI.swift -o "$APP/Contents/MacOS/MacKeyBridge"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>MacKeyBridge</string>
    <key>CFBundleDisplayName</key><string>MacKeyBridge</string>
    <key>CFBundleIdentifier</key><string>local.mackeybridge.client</string>
    <key>CFBundleExecutable</key><string>MacKeyBridge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>3.0</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MacKeyBridge connects to your Windows PC on the local network to send keyboard and trackpad input and to sync the clipboard.</string>
</dict>
</plist>
PLIST

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
