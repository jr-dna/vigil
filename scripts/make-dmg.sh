#!/bin/bash
#
# Builds a drag-to-Applications disk image.
#
#   make-dmg.sh <path-to-Vigil.app> <output.dmg>
#
# Signing and notarization of the resulting image happen in the Makefile, not
# here — the image needs its own signature and its own notarization ticket.
# Notarizing the app inside is not enough: the .dmg carries its own quarantine
# flag when downloaded, and Gatekeeper checks it before anything inside.

set -euo pipefail

APP="${1:?usage: make-dmg.sh <app> <output.dmg>}"
OUT="${2:?usage: make-dmg.sh <app> <output.dmg>}"

VOLUME="Vigil"
STAGING="$(mktemp -d)"
TEMP_DMG="$(mktemp -u).dmg"
MOUNTPOINT="/Volumes/$VOLUME"

cleanup() {
    hdiutil detach "$MOUNTPOINT" -quiet 2>/dev/null || true
    rm -rf "$STAGING"
    rm -f "$TEMP_DMG"
}
trap cleanup EXIT

echo "Staging..."
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Anything left over from a previous run confuses the mount below.
hdiutil detach "$MOUNTPOINT" -quiet 2>/dev/null || true
rm -f "$OUT"

echo "Creating image..."
hdiutil create \
    -srcfolder "$STAGING" \
    -volname "$VOLUME" \
    -fs HFS+ \
    -format UDRW \
    -quiet \
    "$TEMP_DMG"

echo "Laying out the window..."
hdiutil attach "$TEMP_DMG" -mountpoint "$MOUNTPOINT" -nobrowse -quiet

# Best effort. Driving Finder needs Automation permission, and the first run
# will prompt for it; if the user declines, or this is running headless, the
# image still works — it just opens with Finder's default view instead of the
# side-by-side arrangement.
osascript <<APPLESCRIPT 2>/dev/null || echo "  (skipped: Finder automation unavailable)"
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 800, 520}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 112
        set text size of opts to 12
        set position of item "Vigil.app" of container window to {150, 190}
        set position of item "Applications" of container window to {450, 190}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNTPOINT" -quiet

echo "Compressing..."
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -quiet -o "$OUT"

echo "Built $OUT"
