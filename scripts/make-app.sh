#!/usr/bin/env bash
# Builds Octetly.app into dist/, ready to run or to be put in a dmg.
#
# SwiftPM produces a bare executable, so the .app around it is assembled here:
# the universal binary, the resource bundle SwiftPM generates for
# Sources/octetly/Resources, an .icns made from AppIcon.png, and the Info.plist
# in packaging/ with the version filled in from the VERSION file.
#
#   scripts/make-app.sh                        # unsigned; for local use
#   scripts/make-app.sh --sign "Developer ID Application: ..."
#
# Signing is what a release needs and what a local build has no way to do, so it
# is a flag rather than a step of its own. Nothing here talks to the network.
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
      echo "Usage: scripts/make-app.sh [--sign <identity>]" >&2
      exit 1
      ;;
  esac
done

VERSION=$(tr -d '[:space:]' < VERSION)
if [ -z "$VERSION" ]; then
  echo "Error: VERSION is empty." >&2
  exit 1
fi

# Both architectures, so that the one dmg runs on Intel and Apple Silicon alike.
# The flags have to match on every swift invocation below: --show-bin-path
# answers for the flags it is given, and answering for a different build would
# hand back a path that holds the wrong binary (or nothing at all).
ARCHS=(--arch arm64 --arch x86_64)

echo "Building Octetly $VERSION (universal) ..."
swift build -c release "${ARCHS[@]}"
BIN_PATH=$(swift build -c release "${ARCHS[@]}" --show-bin-path)

APP="dist/Octetly.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/Octetly" "$APP/Contents/MacOS/Octetly"

# Both architectures have to be in there. A single-architecture binary still
# runs on the machine that built it, so without this check the mistake would
# only show up on somebody else's Mac.
if ! lipo -archs "$APP/Contents/MacOS/Octetly" | grep -q "arm64" \
  || ! lipo -archs "$APP/Contents/MacOS/Octetly" | grep -q "x86_64"; then
  echo "Error: the binary is not universal: $(lipo -archs "$APP/Contents/MacOS/Octetly")" >&2
  exit 1
fi

# SwiftPM puts Sources/octetly/Resources into a bundle beside the executable,
# named <package>_<target>.bundle. Its contents are copied into the app's own
# Contents/Resources rather than the bundle itself being copied in: the accessor
# SwiftPM generates looks for that bundle inside Bundle.main.bundleURL, which for
# an app is the top level of the .app -- where nothing but Contents may live and
# where anything else breaks the signature. BundledResource.swift is the other
# half of this: it asks the main bundle first, and only falls back to
# Bundle.module for `swift run`.
RESOURCE_BUNDLE="$BIN_PATH/Octetly_Octetly.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "Error: no resource bundle at $RESOURCE_BUNDLE." >&2
  exit 1
fi
# A macOS bundle keeps its payload under Contents/Resources; on other platforms
# SwiftPM writes it flat. Both are handled so that this does not turn on which
# machine ran the build.
BUNDLE_PAYLOAD="$RESOURCE_BUNDLE"
if [ -d "$RESOURCE_BUNDLE/Contents/Resources" ]; then
  BUNDLE_PAYLOAD="$RESOURCE_BUNDLE/Contents/Resources"
fi
for resource in "$BUNDLE_PAYLOAD"/*; do
  # The bundle's own Info.plist describes the bundle, not the app, and the app
  # has one of its own.
  [ "$(basename "$resource")" = "Info.plist" ] && continue
  cp -R "$resource" "$APP/Contents/Resources/"
done

# oui.csv going missing does not stop the app: OUIDatabase falls back to an empty
# table, and every device reads as an unknown vendor. That is a hard thing to
# notice in a release, so it is checked here instead.
if [ ! -f "$APP/Contents/Resources/oui.csv" ]; then
  echo "Error: oui.csv did not make it into the app." >&2
  echo "  Without it every vendor reads as Unknown." >&2
  exit 1
fi

# The .icns is generated rather than committed: AppIcon.png is the master, and a
# second copy of it in another format is a second thing to keep in step.
# The master is 512x512, so the 1024 slot is left out rather than filled by
# upscaling -- macOS falls back to the largest size present.
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
MASTER="Sources/octetly/Resources/AppIcon.png"
sips -z 16 16     "$MASTER" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$MASTER" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$MASTER" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$MASTER" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$MASTER" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$MASTER" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$MASTER" --out "$ICONSET/icon_512x512.png"    >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

sed "s/__VERSION__/${VERSION}/g" packaging/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
if grep -q "__VERSION__" "$APP/Contents/Info.plist"; then
  echo "Error: the version placeholder is still in the Info.plist." >&2
  exit 1
fi

if [ -n "$IDENTITY" ]; then
  # There is no nested code to sign first: what went into Contents/Resources is
  # data (a csv and two images), and the only executable is Contents/MacOS.
  # --options runtime (the hardened runtime) is what notarization requires;
  # --timestamp is what keeps the signature valid after the certificate expires.
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "Built $APP"
