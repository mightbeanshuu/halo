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
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>Halo drives Terminal windows and the Dock via AppleScript.</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PL
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
rm -rf dist/dmgroot && mkdir -p dist/dmgroot && cp -R "$APP" dist/dmgroot/ && ln -s /Applications dist/dmgroot/Applications
cp README.md dist/dmgroot/README.md
hdiutil create -volname "Halo" -srcfolder dist/dmgroot -ov -format UDZO "dist/Halo-$VERSION.dmg" >/dev/null
rm -rf dist/dmgroot
echo "built dist/Halo-$VERSION.dmg"
ls -la dist
