#!/bin/bash
# Build "NTFS Drive.app". Usage: ./build.sh [output-dir]   (default: /Applications)
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:-/Applications}"
mkdir -p "$OUT"
APP="$OUT/NTFS Drive.app"
rm -rf "$APP"
osacompile -o "$APP" src/NTFSDrive.applescript
cp scripts/mount-ntfs.sh scripts/eject-ntfs.sh "$APP/Contents/Resources/"
chmod +x "$APP/Contents/Resources/"*.sh
cp icon/NTFS.icns "$APP/Contents/Resources/applet.icns"
rm -f "$APP/Contents/Resources/Assets.car"
P="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$P" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile applet" "$P" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string applet" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.local.ntfsdrive" "$P" 2>/dev/null || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.local.ntfsdrive" "$P"
codesign --force --deep -s - "$APP"
touch "$APP"
echo "Built: $APP"
