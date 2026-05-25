#!/usr/bin/env bash
# Build a Developer-ID-signed Release archive of Writ and package it as a
# DMG that's ready for distribution.
#
# Usage:
#   ./Scripts/make-release.sh            # build, sign, package
#   ./Scripts/make-release.sh --notarize # also submit to Apple for notarization
#                                        # (needs `xcrun notarytool store-credentials`)
#
# Prerequisites:
#   - Xcode + a `Developer ID Application` cert for team Q34D9AYJ95
#     installed in the login keychain.
#   - rsvg-convert (only used if the app icon needs regeneration).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

NOTARIZE=0
for arg in "$@"; do
  case "$arg" in
    --notarize) NOTARIZE=1 ;;
  esac
done

# Regenerate Xcode project so any project.yml edits land in the archive.
xcodegen generate >/dev/null

# Archive — Release config in project.yml drives signing style + identity.
echo "==> Building Release archive..."
rm -rf build/Writ.xcarchive
xcodebuild \
  -project Writ.xcodeproj \
  -scheme Writ \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath build/Writ.xcarchive \
  archive | tail -5

# Export Developer-ID-signed .app
echo "==> Exporting signed Writ.app..."
rm -rf build/Writ-export
xcodebuild \
  -exportArchive \
  -archivePath build/Writ.xcarchive \
  -exportPath build/Writ-export \
  -exportOptionsPlist Scripts/ExportOptions.plist | tail -3

APP=build/Writ-export/Writ.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/Writ-${VERSION}.dmg"
VOLNAME="Writ ${VERSION}"
echo "==> Building $DMG..."

# Stage the contents the user will see when they mount the DMG:
#   - Writ.app                 (the bundle to drag)
#   - Applications             (symlink target for the drag gesture)
#   - .background/             (hidden, holds the window background image)
#   - .DS_Store                (written by Finder after we set the layout)
# The new minimalist background already shows "Drag Writ to Applications"
# in-image, so we no longer ship a README.rtf — would just clutter the
# tight visual.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp Scripts/dmg-resources/background.png "$STAGE/.background/background.png"

# Build a writable DMG first so we can mount it and have Finder
# stamp the window layout (background image, icon positions, window
# size) into a .DS_Store. The final DMG is converted to UDZO
# read-only-compressed at the end.
RW_DMG=$(mktemp -t writ-rw).dmg
rm -f "$RW_DMG"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW \
  -fs HFS+ -fsargs "-c c=64,a=16,e=16" "$RW_DMG" | tail -2

echo "==> Mounting for Finder layout..."
# Let hdiutil mount at the default /Volumes/<volname>. Finder only
# scripts disks it has registered, and that watch is limited to
# /Volumes. Custom -mountpoint paths produce -1728 "can't get disk".
hdiutil attach "$RW_DMG" -noautoopen | tail -2
MOUNT_DIR="/Volumes/$VOLNAME"
# Beat for Finder to register the new volume.
sleep 2

# Drive Finder via AppleScript to position icons, hide the toolbar,
# and pin the window to a compact 540×380 frame with the custom
# background. Sleep a beat between each command — Finder's view
# settings sometimes don't stick if we don't yield.
osascript <<EOF
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 200, 800, 620}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.png"
    -- Icon positions chosen to align with the arrow in the background
    -- image: Writ.app sits left of the arrow tail, Applications right of
    -- the arrow head, both at the same vertical level (~y=150 — one
    -- Finder grid row above the previous y=250 so the icons sit closer
    -- to the arrow rather than overlapping the "Drag…" caption).
    set position of item "Writ.app" of container window to {150, 150}
    set position of item "Applications" of container window to {450, 150}
    update without registering applications
    delay 1
    close
  end tell
end tell
EOF

# Make sure .DS_Store flushes before we detach.
sync
sleep 2
hdiutil detach "$MOUNT_DIR" -force | tail -2 || true
rmdir "$MOUNT_DIR" 2>/dev/null || true

# Convert read/write → read-only compressed for distribution.
rm -f "$DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" | tail -2
rm -f "$RW_DMG"

# Sign the DMG itself so Gatekeeper accepts it.
echo "==> Signing DMG..."
codesign --sign "Developer ID Application" --timestamp "$DMG"

# Verify
codesign --verify --deep --strict --verbose=2 "$APP" | tail -3
codesign --verify --verbose=2 "$DMG" | tail -2

if [ "$NOTARIZE" = "1" ]; then
  echo "==> Submitting DMG for notarization..."
  xcrun notarytool submit "$DMG" --keychain-profile writ-notary --wait
  xcrun stapler staple "$DMG"
fi

echo
echo "Done."
echo "  archive: build/Writ.xcarchive"
echo "  app:     $APP"
echo "  dmg:     $DMG"
echo "  size:    $(du -h "$DMG" | cut -f1)"
