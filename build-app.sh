#!/bin/bash
# Assembles Pomace.app from the SPM build. There is no .xcodeproj by design — the bundle is
# scripted so it is reproducible and reviewable in a diff (ADR-0013).
#
# Signing identity: sign by SHA-1 hash, not name. Two identical "Developer ID Application"
# certificates in different keychains make --sign by name ambiguous, and codesign then
# produces a BROKEN signature while reporting success.
#   security find-identity -v -p codesigning
set -eu
CONFIG="${1:-debug}"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/Pomace.app"
IDENTITY="${POMACE_SIGN_ID:-85E7645225011373853E0C0F50CF9967974BB7BE}"
VERSION="${POMACE_VERSION:-}"

cd "$HERE"
BUILD_ARGS=(-c "$CONFIG" --product PomaceApp)
if [ "$CONFIG" = "release" ]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "building ($CONFIG)…"
swift build "${BUILD_ARGS[@]}"
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/PomaceApp"
PRODUCTS_DIR="$(dirname "$BIN")"
RESOURCE_BUNDLE="$PRODUCTS_DIR/Pomace_PomaceApp.bundle"

if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "missing processed SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi

if [ ! -f "$HERE/build/applesauce" ] || [ "$HERE/tools/applesauce/Cargo.lock" -nt "$HERE/build/applesauce" ]; then
  scripts/build-applesauce.sh
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/Pomace"
cp "$HERE/build/applesauce" "$APP/Contents/Helpers/applesauce"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/Resources/Pomace.icns" "$APP/Contents/Resources/Pomace.icns"
# SwiftPM keeps processed localization resources beside the executable rather than in it.
# Copy the bundle into the application so `Bundle.module` resolves after distribution.
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
# The scheduled-sweep agent ships inside the bundle so it is covered by the signature and
# removed cleanly when the app is deleted (ADR-0005).
cp "$HERE/Resources/com.sdelavega.Pomace.Sweep.plist" "$APP/Contents/Library/LaunchAgents/"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/Helpers/applesauce"
  codesign --force --options runtime --timestamp \
    --entitlements "$HERE/Resources/Pomace.entitlements" \
    --sign "$IDENTITY" "$APP"
  codesign --verify --strict "$APP" && echo "signed with Developer ID"
else
  codesign --force --options runtime --sign - "$APP/Contents/Helpers/applesauce"
  codesign --force --sign - "$APP"
  echo "ad-hoc signed (Developer ID identity not found)"
fi

echo "built: $APP"
