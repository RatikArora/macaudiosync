#!/bin/bash
# Builds dist/MacAudioSync.app — a shareable, double-clickable, UNIVERSAL
# (Apple Silicon + Intel) app that wraps the audiosync engines with a simple
# UI. Works on any Mac running macOS 13+.
#
# Share it by AirDropping/zipping dist/MacAudioSync.app. It is ad-hoc signed,
# so on another Mac the FIRST launch needs: right-click the app -> Open ->
# Open (Gatekeeper), or `xattr -cr MacAudioSync.app` after unzipping.
set -euo pipefail
cd "$(dirname "$0")"

echo "Building arm64..."
swift build -c release --triple arm64-apple-macosx13.0
echo "Building x86_64..."
swift build -c release --triple x86_64-apple-macosx13.0

ARM=.build/arm64-apple-macosx/release
X86=.build/x86_64-apple-macosx/release

APP=dist/MacAudioSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp App/Info.plist "$APP/Contents/Info.plist"
cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

for bin in MacAudioSyncApp audiosync-send audiosync-recv; do
    lipo -create "$ARM/$bin" "$X86/$bin" -output "$APP/Contents/MacOS/$bin"
    codesign --force --sign - "$APP/Contents/MacOS/$bin"
done
codesign --force --sign - "$APP"

echo
lipo -info "$APP/Contents/MacOS/MacAudioSyncApp"
echo "Built $APP"
echo "Share it: zip or AirDrop the app. On the other Mac: right-click -> Open the first time."
