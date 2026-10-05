#!/bin/bash
# Builds PieFlow.app (universal) and a shareable DMG.
# Usage: scripts/build.sh            -> build/PieFlow.app and dist/PieFlow-<version>.dmg
#        scripts/build.sh --no-dmg   -> app only
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="1.0.1"
BUILD_NUM="$(date +%Y%m%d%H%M)"
APP="build/PieFlow.app"
# The macOS 27 SDK turns SwiftUI property wrappers into macros whose plugin ships only with full Xcode.
# The 26 SDK builds cleanly with Command Line Tools alone, and the app still runs on macOS 14 and later.
SDK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | head -1 || true)"
if [ -n "$SDK" ]; then export SDKROOT="$SDK"; fi

echo "==> Compiling (universal, SDK: ${SDKROOT:-default})"
swift build -c release --arch arm64 --arch x86_64
BIN=".build/out/Products/Release/PieFlow"
[ -f "$BIN" ] || BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/PieFlow"

if [ ! -x Assets/bin/whisper-cli ]; then
  echo "==> whisper-cli missing, building it"
  scripts/build-whisper.sh
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin" "$APP/Contents/Resources/Fonts"
cp "$BIN" "$APP/Contents/MacOS/PieFlow"
cp Assets/bin/whisper-cli "$APP/Contents/Resources/bin/"
cp Assets/Fonts/*.ttf "$APP/Contents/Resources/Fonts/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>PieFlow</string>
  <key>CFBundleDisplayName</key><string>PieFlow</string>
  <key>CFBundleIdentifier</key><string>app.pieflow.mac</string>
  <key>CFBundleExecutable</key><string>PieFlow</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUM}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSMicrophoneUsageDescription</key><string>PieFlow listens while you hold your dictation key and while Notetaker is recording.</string>
  <key>NSAppleEventsUsageDescription</key><string>PieFlow can mute system audio while you dictate.</string>
  <key>NSHumanReadableCopyright</key><string>PieFlow for Mac. Personal use.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad hoc, stable requirement)"
# An ad hoc signature's default designated requirement is the build's cdhash, so macOS forgets
# Microphone/Accessibility/Input Monitoring grants after every rebuild. Pinning the requirement to the
# bundle identifier keeps grants valid across updates.
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/bin/whisper-cli"
codesign --force --sign - --timestamp=none --identifier app.pieflow.mac \
  --requirements '=designated => identifier "app.pieflow.mac"' "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated
codesign --verify --deep --strict "$APP" && echo "    signature OK"

if [ "${1:-}" = "--no-dmg" ]; then echo "Done: $APP"; exit 0; fi

echo "==> Building DMG"
mkdir -p dist
STAGE="build/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp docs/INSTALL.txt "$STAGE/Read Me First.txt"
DMG="dist/PieFlow-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "PieFlow" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null
echo "Done: $DMG ($(du -h "$DMG" | cut -f1))"
