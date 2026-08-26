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

echo "building ($CONFIG)…"
swift build -c "$CONFIG" --product PomaceApp
BIN="$(swift build -c "$CONFIG" --product PomaceApp --show-bin-path)/PomaceApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN" "$APP/Contents/MacOS/Pomace"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
# The scheduled-sweep agent ships inside the bundle so it is covered by the signature and
# removed cleanly when the app is deleted (ADR-0005).
cp "$HERE/Resources/org.pomace.Pomace.Sweep.plist" "$APP/Contents/Library/LaunchAgents/"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  codesign --force --options runtime \
    --entitlements "$HERE/Resources/Pomace.entitlements" \
    --sign "$IDENTITY" "$APP"
  codesign --verify --strict "$APP" && echo "signed with Developer ID"
else
  codesign --force --sign - "$APP"
  echo "ad-hoc signed (Developer ID identity not found)"
fi

echo "built: $APP"
