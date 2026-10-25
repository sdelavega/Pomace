#!/bin/bash
# Build and verify a DMG and signed appcast; publishing is a separate step.
set -euo pipefail
source "$(dirname "$0")/release-tools.sh"
cd "$ROOT"
fail() { echo "$*" >&2; exit 1; }
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || fail 'usage: release.sh VERSION [--dry-run]'
VERSION="$1"
DRY_RUN=0
if [ "$#" = 2 ]; then
  [ "$2" = --dry-run ] || fail 'Unknown release option'
  DRY_RUN=1
fi
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ( "$DRY_RUN" = 1 && "$VERSION" = 0.0.0-dryrun ) ]] || fail 'VERSION must be x.y.z'
# notarytool keychain profile; any profile for the same Developer ID team works.
NOTARY_PROFILE="${POMACE_NOTARY_PROFILE:-Pomace Notary}"
[[ -n "$NOTARY_PROFILE" && "$NOTARY_PROFILE" != *[[:cntrl:]]* ]] || fail 'Invalid POMACE_NOTARY_PROFILE'
NOTES="release/$VERSION.md"
if [ "$DRY_RUN" = 1 ] && [ ! -f "$NOTES" ]; then NOTES=release/1.1.0.md; fi
[ -s "$NOTES" ] || fail 'Missing release notes'
mkdir -p dist
# Invalidate previous proof before starting work, including on a failed rebuild.
rm -f dist/MANIFEST
WORK="$(mktemp -d "$ROOT/dist/.release.XXXXXX")"
MOUNT="$WORK/mount"
ATTACHED=0
cleanup() {
  local status=$?
  trap - EXIT
  if [ "$ATTACHED" = 1 ]; then
    hdiutil detach "$MOUNT" || { echo 'Detach failed; retained release work directory' >&2; exit 1; }
  fi
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

IDENTITY="${POMACE_SIGN_ID:-}"
# R1: the gate calls dry-run, so it skips the clean-tree check and recursive gate.
if [ "$DRY_RUN" != 1 ]; then
  [ -z "$(git status --porcelain)" ] || fail 'Release requires a clean tree'
  scripts/gate.sh
  IDENTITY="${POMACE_SIGN_ID:?Set POMACE_SIGN_ID to the Developer ID certificate SHA-1}"
  security find-identity -v -p codesigning > "$WORK/identities"
  python3 - "$WORK/identities" "$IDENTITY" <<'IDENTITY_CHECK'
from pathlib import Path
import re, sys
matches = re.findall(r'\b' + re.escape(sys.argv[2]) + r' "(Developer ID Application:[^"\n]+)"', Path(sys.argv[1]).read_text())
if not re.fullmatch(r"[A-Fa-f0-9]{40}", sys.argv[2]) or len(matches) != 1:
    sys.exit("A unique Developer ID Application identity is required")
IDENTITY_CHECK
fi
prepare_tools
POMACE_VERSION="$VERSION" POMACE_SIGN_ID="$IDENTITY" POMACE_SIGN_ADHOC="$DRY_RUN" ./build-app.sh release
scripts/check-bundle.sh --universal build/Pomace.app
mkdir -p "$WORK/image" "$WORK/feed"
ditto build/Pomace.app "$WORK/image/Pomace.app"
if [ "$DRY_RUN" = 1 ]; then
  python3 release/metadata.py key "$WORK/ed-key" "$WORK/image/Pomace.app"
  codesign --force --sign - "$WORK/image/Pomace.app"
fi
ln -s /Applications "$WORK/image/Applications"
DMG="dist/Pomace-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -srcfolder "$WORK/image" -volname "Pomace $VERSION" -format UDZO "$DMG"
if [ "$DRY_RUN" = 1 ]; then
  codesign --force --sign - "$DMG"
  KEY_ARGS=(--ed-key-file "$WORK/ed-key")
else
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature "$DMG"
  mkdir -p "$MOUNT"
  ATTACHED=1
  hdiutil attach "$DMG" -readonly -nobrowse -mountpoint "$MOUNT"
  spctl -a -t exec "$MOUNT/Pomace.app"
  hdiutil detach "$MOUNT"
  ATTACHED=0
  KEY_ARGS=(--account Pomace)
  fetch_appcast "$WORK/feed/appcast.xml"
  if [ ! -s "$WORK/feed/appcast.xml" ]; then rm "$WORK/feed/appcast.xml"; fi
fi
# No stale dist archives or keys can enter this directory.
cp "$DMG" "$WORK/feed/Pomace-$VERSION.dmg"
python3 release/metadata.py notes "$NOTES" "$WORK/feed/Pomace-$VERSION.html"
"$TOOLS/generate_appcast" "${KEY_ARGS[@]}" --download-url-prefix \
  "https://github.com/sdelavega/Pomace/releases/download/v$VERSION/" \
  --embed-release-notes --maximum-deltas 0 --maximum-versions 0 "$WORK/feed"
python3 release/metadata.py check-feed "$VERSION" "$DMG" "$WORK/feed/appcast.xml" "$DRY_RUN" \
  "$WORK/image/Pomace.app" "$TOOLS/sign_update"
cp "$WORK/feed/appcast.xml" dist/appcast.xml
SHA="$(shasum -a 256 "$DMG")"
python3 release/metadata.py manifest "$VERSION" "$(git rev-parse HEAD)" "${SHA%% *}" "$DRY_RUN"
printf 'Verified %s (dry-run=%s)\n' "$DMG" "$DRY_RUN"
