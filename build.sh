#!/usr/bin/env bash
# Builds Halo.app (deck + overlay + CLI inside) and dist/Halo.dmg
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${1:-$(cat VERSION)}"
APP="dist/Halo.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
swiftc -O overlay.swift -o "$APP/Contents/Resources/bin/halo-overlay"
swiftc -O deck.swift    -o "$APP/Contents/Resources/bin/halo-deck"
cp halo overlay.swift deck.swift README.md VERSION "$APP/Contents/Resources/"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
chmod +x "$APP/Contents/Resources/halo"
# launcher: opens the deck around the front Terminal window and installs the CLI symlink
cat > "$APP/Contents/MacOS/Halo" <<'SH'
#!/usr/bin/env bash
RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
mkdir -p "$HOME/.local/bin"; ln -sf "$RES/halo" "$HOME/.local/bin/halo"
[ -w /opt/homebrew/bin ] && ln -sf "$RES/halo" /opt/homebrew/bin/halo
exec /usr/bin/python3 "$RES/halo" deck
SH
chmod +x "$APP/Contents/MacOS/Halo"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Halo</string>
  <key>CFBundleDisplayName</key><string>Halo</string>
  <key>CFBundleIdentifier</key><string>dev.anshu.halo</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleExecutable</key><string>Halo</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSMicrophoneUsageDescription</key><string>Halo dictates prompts with on-device speech.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Halo turns your voice into prompts and to-dos.</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Halo drives Terminal windows and the Dock via AppleScript.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
# --- designed DMG: background, icon layout, volume icon ---
STAGE=dist/dmgroot; rm -rf "$STAGE" && mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
cp assets/dmg-background.png "$STAGE/.background/bg.png"
cp assets/AppIcon.icns "$STAGE/.VolumeIcon.icns"
for v in /Volumes/Halo*; do [ -d "$v" ] && hdiutil detach "$v" -force -quiet; done   # stale mounts break the Finder step
RW="dist/Halo-rw.dmg"; rm -f "$RW"
hdiutil create -volname "Halo" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW" >/dev/null
ATTACH=$(hdiutil attach -readwrite -noverify -noautoopen "$RW")
DEV=$(echo "$ATTACH" | grep -E '^/dev/' | head -1 | awk '{print $1}')
MNT=$(echo "$ATTACH" | grep -E '/Volumes/' | head -1 | sed -E 's/.*(\/Volumes\/.*)$/\1/')
sleep 2.5
cp assets/AppIcon.icns "$MNT/.VolumeIcon.icns"   # hdiutil -srcfolder drops it, so place it on the mounted volume
command -v SetFile >/dev/null && SetFile -a C "$MNT" || xattr -wx com.apple.FinderInfo "0000000000000000040000000000000000000000000000000000000000000000" "$MNT" 2>/dev/null || true
osascript <<'AS' || true
tell application "Finder"
  tell disk "Halo"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set position of item "Halo.app" of container window to {165, 200}
    set position of item "Applications" of container window to {495, 200}
    set background picture of opts to POSIX file "/Volumes/Halo/.background/bg.png"
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
AS
sync; hdiutil detach "$DEV" -quiet || hdiutil detach "$DEV" -force -quiet
rm -f "dist/Halo-$VERSION.dmg"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "dist/Halo-$VERSION.dmg" >/dev/null
rm -rf "$RW" "$STAGE"
echo "built dist/Halo-$VERSION.dmg"
ls -la dist
