#!/bin/bash
# Packs a built Pawshot.app into build/Pawshot-<version>.dmg: a window with a background, the app
# on the left, Applications on the right, drag one onto the other. Run through `make dist`.
#
# The window layout is set by Finder over AppleScript, so the first run asks for permission to
# control Finder (System Settings → Privacy & Security → Automation).

set -euo pipefail

APP="$1"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
STAGE="build/dmg"
RW="build/dmg-rw.dmg"
OUT="build/Pawshot-$VERSION.dmg"
VOLUME="/Volumes/Pawshot"

rm -rf "$STAGE" "$RW" "$OUT"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/Pawshot.app"
ln -s /Applications "$STAGE/Applications"
swift Tools/GenerateDMGBackground.swift "$STAGE/.background"
tiffutil -cathidpicheck "$STAGE/.background/background.png" \
	"$STAGE/.background/background@2x.png" -out "$STAGE/.background/background.tiff" >/dev/null 2>&1
rm "$STAGE/.background/"*.png

[ -d "$VOLUME" ] && hdiutil detach "$VOLUME" -quiet
hdiutil create -srcfolder "$STAGE" -volname Pawshot -fs HFS+ -format UDRW -ov "$RW" -quiet
hdiutil attach "$RW" -readwrite -noverify -noautoopen -quiet

# Positions must match the arrow in GenerateDMGBackground.swift; bounds are 640×400 plus the title bar.
osascript <<'EOF'
tell application "Finder"
	tell disk "Pawshot"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set bounds of container window to {200, 120, 840, 548}
		set opts to icon view options of container window
		set arrangement of opts to not arranged
		set icon size of opts to 128
		set text size of opts to 13
		set background picture of opts to file ".background:background.tiff"
		set position of item "Pawshot.app" of container window to {160, 190}
		set position of item "Applications" of container window to {480, 190}
		update without registering applications
		delay 1
		close
	end tell
end tell
EOF

sync
hdiutil detach "$VOLUME" -quiet
hdiutil convert "$RW" -format UDZO -o "$OUT" -quiet
rm -rf "$STAGE" "$RW"
echo "packed: $OUT"
