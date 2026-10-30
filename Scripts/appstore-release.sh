#!/usr/bin/env bash
# Build a Mac App Store archive of Writ and export a signed installer package
# ready for submission to App Store Connect.
#
# This is Writ's second shipping channel. Scripts/make-release.sh still owns
# the Developer ID + notarized DMG + Homebrew cask path and is untouched by
# this script: the two share project.yml and nothing else, and they write to
# different directories under build/ so one commit can produce both a DMG and
# a .pkg.
#
# Usage:
#   ./Scripts/appstore-release.sh             # archive + export a local .pkg
#   ./Scripts/appstore-release.sh --validate  # also validate it against Apple
#   ./Scripts/appstore-release.sh --upload    # also upload to App Store Connect
#
# Prerequisites:
#   - Xcode, plus an `Apple Distribution` certificate and a `3rd Party Mac
#     Developer Installer` certificate for team Q34D9AYJ95 in the login
#     keychain. These are NOT the Developer ID certs make-release.sh uses, and
#     having one does not give you the other — create both in the Apple
#     Developer portal (Certificates, Identifiers & Profiles → Certificates →
#     +) and download them before running. Without them `-exportArchive`
#     fails; that failure means "go make a certificate", never "relax the
#     signing settings".
#   - App Store Connect rejects a CFBundleVersion it has already seen, so bump
#     CURRENT_PROJECT_VERSION in project.yml for every upload.
#   - For --validate / --upload, an App Store Connect API key:
#       APP_STORE_API_KEY     the key ID, e.g. X6SAACPDU4
#       APP_STORE_API_ISSUER  the issuer UUID from App Store Connect →
#                             Users and Access → Integrations → Keys
#     with the matching AuthKey_<key-id>.p8 in ~/.private_keys/.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCHIVE="build/Writ-AppStore.xcarchive"
EXPORT_DIR="build/Writ-AppStore-export"
PKG="$EXPORT_DIR/Writ.pkg"

VALIDATE=0
UPLOAD=0
for arg in "$@"; do
  case "$arg" in
    --validate) VALIDATE=1 ;;
    --upload)   UPLOAD=1 ;;
    --help|-h)
      echo "Usage: $0 [--validate] [--upload]"
      echo "  --validate   Validate the exported .pkg against App Store Connect"
      echo "  --upload     Upload the exported .pkg to App Store Connect"
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 1
      ;;
  esac
done

# altool locates the private key on its own, searching ~/private_keys,
# ~/.private_keys and ~/.appstoreconnect/private_keys for AuthKey_<id>.p8. So
# we only check that the key is already in place and never copy it anywhere: a
# signing key duplicated into a build tree is a signing key waiting to leak.
require_api_credentials() {
  if [ -z "${APP_STORE_API_KEY:-}" ] || [ -z "${APP_STORE_API_ISSUER:-}" ]; then
    echo "ERROR: APP_STORE_API_KEY (key ID) and APP_STORE_API_ISSUER (issuer UUID) must be set." >&2
    exit 1
  fi
  if [ ! -f "$HOME/.private_keys/AuthKey_${APP_STORE_API_KEY}.p8" ]; then
    echo "ERROR: ~/.private_keys/AuthKey_${APP_STORE_API_KEY}.p8 not found." >&2
    echo "  Download the key from App Store Connect and put it there (chmod 600)." >&2
    exit 1
  fi
}

# Check credentials up front rather than after a ten-minute archive, since we
# already know this run is going to need them.
if [ "$VALIDATE" = "1" ] || [ "$UPLOAD" = "1" ]; then
  require_api_credentials
fi

# Regenerate the Xcode project so project.yml edits reach the archive — the
# App Store Info.plist keys and the PrivacyInfo.xcprivacy resource both live
# there, and a stale Writ.xcodeproj would silently omit them.
xcodegen generate >/dev/null

echo "==> Building App Store archive..."
# Remove only our own two directories. build/ is shared with make-release.sh,
# so a blanket `rm -rf build` would destroy the DMG channel's archive, export
# and signed disk image.
rm -rf "$ARCHIVE" "$EXPORT_DIR"
# 'generic/platform=macOS' rather than 'platform=macOS': an archive meant for
# distribution must not be pinned to this Mac's architecture.
xcodebuild \
  -project Writ.xcodeproj \
  -scheme Writ \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  archive | tail -5

APP_PLIST="$ARCHIVE/Products/Applications/Writ.app/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")
BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")

echo "==> Exporting App Store .pkg for $VERSION ($BUILD)..."
# No -allowProvisioningUpdates here on purpose: that flag lets xcodebuild mint
# distribution certificates in the portal behind your back. Certificates get
# created deliberately, by a human, once.
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist Scripts/ExportOptions-AppStore.plist | tail -3

if [ "$VALIDATE" = "1" ]; then
  echo "==> Validating $PKG..."
  xcrun altool --validate-app \
    -f "$PKG" \
    -t macos \
    --apiKey "$APP_STORE_API_KEY" \
    --apiIssuer "$APP_STORE_API_ISSUER"
fi

if [ "$UPLOAD" = "1" ]; then
  echo "==> Uploading $PKG to App Store Connect..."
  xcrun altool --upload-app \
    -f "$PKG" \
    -t macos \
    --apiKey "$APP_STORE_API_KEY" \
    --apiIssuer "$APP_STORE_API_ISSUER"
  echo "    Uploaded. The build shows up in App Store Connect after processing."
fi

echo
echo "Done."
echo "  version: $VERSION ($BUILD)"
echo "  archive: $ARCHIVE"
echo "  pkg:     $PKG"
echo "  size:    $(du -h "$PKG" | cut -f1)"
