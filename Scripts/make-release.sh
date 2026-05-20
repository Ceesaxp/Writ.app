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

# Archive
echo "==> Building Release archive..."
rm -rf build/Writ.xcarchive
xcodebuild \
  -project Writ.xcodeproj \
  -scheme Writ \
  -configuration Release \
  -destination 'platform=macOS' \
  -archivePath build/Writ.xcarchive \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM=Q34D9AYJ95 \
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
echo "==> Building $DMG..."

# Stage the app + Applications symlink, package into a UDZO DMG
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Writ" -srcfolder "$STAGE" -ov -format UDZO "$DMG" | tail -2

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
