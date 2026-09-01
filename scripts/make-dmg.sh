#!/usr/bin/env bash
# Puts dist/Octetly.app into dist/Octetly_<version>_universal.dmg.
#
# Run scripts/make-app.sh first. Kept separate from it so that notarization can
# happen in between: the ticket is stapled to the .app, and the dmg has to be
# built from the stapled copy for the app inside it to carry one.
#
#   scripts/make-dmg.sh
#   scripts/make-dmg.sh --sign "Developer ID Application: ..."
set -euo pipefail

cd "$(dirname "$0")/.."

IDENTITY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --sign)
      IDENTITY="${2:-}"
      if [ -z "$IDENTITY" ]; then
        echo "Error: --sign needs an identity." >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Usage: scripts/make-dmg.sh [--sign <identity>]" >&2
      exit 1
      ;;
  esac
done

VERSION=$(tr -d '[:space:]' < VERSION)
APP="dist/Octetly.app"
DMG="dist/Octetly_${VERSION}_universal.dmg"

if [ ! -d "$APP" ]; then
  echo "Error: $APP does not exist. Run scripts/make-app.sh first." >&2
  exit 1
fi

# The version in the name has to be the version in the app, or the download and
# what it installs disagree.
BUILT_VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")
if [ "$BUILT_VERSION" != "$VERSION" ]; then
  echo "Error: $APP is version ${BUILT_VERSION}, but VERSION says ${VERSION}." >&2
  echo "  Re-run scripts/make-app.sh." >&2
  exit 1
fi

STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
# The Applications symlink is what makes the window a drag-and-drop install.
ln -s /Applications "$STAGING/Applications"

rm -f "$DMG"
hdiutil create -volname "Octetly" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

if [ -n "$IDENTITY" ]; then
  # Signing the dmg itself is separate from signing the app inside it. Without
  # it the download is unsigned even though what it installs is not.
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi

echo "Built $DMG"
