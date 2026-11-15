#!/bin/bash
# Build the "NTFS Drive" menu bar app.
# Usage: ./build.sh [output-dir]      (default: /Applications)
# Needs only the Xcode Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-/Applications}"
VERSION="2.0.0"
APP="$OUT/NTFS Drive.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Compiling…"
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -framework AppKit -framework DiskArbitration -framework ServiceManagement -framework UserNotifications \
    src/NTFSDrive.swift -o "$TMP/NTFSDrive-$arch"
done
lipo -create "$TMP/NTFSDrive-arm64" "$TMP/NTFSDrive-x86_64" -output "$TMP/NTFSDrive"

echo "Packaging…"
mkdir -p "$OUT"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$TMP/NTFSDrive" "$APP/Contents/MacOS/NTFSDrive"
cp scripts/mount-ntfs.sh scripts/eject-ntfs.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh
cp icon/NTFS.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>NTFS Drive</string>
  <key>CFBundleDisplayName</key><string>NTFS Drive</string>
  <key>CFBundleIdentifier</key><string>com.local.ntfsdrive</string>
  <key>CFBundleExecutable</key><string>NTFSDrive</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP"
touch "$APP"
echo "Built: $APP"
