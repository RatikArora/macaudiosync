#!/bin/bash
# Turns App/AppIcon-1024.png (from `swift App/make-icon.swift`) into
# App/AppIcon.icns at every size macOS needs. Run after editing the icon:
#   swift App/make-icon.swift && ./App/make-iconset.sh
set -euo pipefail
cd "$(dirname "$0")"

SRC=AppIcon-1024.png
SET=AppIcon.iconset
rm -rf "$SET"
mkdir -p "$SET"

# name → pixel size
gen() { sips -z "$2" "$2" "$SRC" --out "$SET/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png      128
gen icon_128x128@2x.png   256
gen icon_256x256.png      256
gen icon_256x256@2x.png   512
gen icon_512x512.png      512
gen icon_512x512@2x.png   1024

iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET"
echo "wrote App/AppIcon.icns"
