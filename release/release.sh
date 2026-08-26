#!/bin/bash
# Produces the direct-download release artifact: a notarized ZIP containing Pomace.app.
# Credentials remain in the local keychain, never in this repository.
set -euo pipefail

VERSION="${1:?usage: release.sh <version>}"
# Reuse the local profile already used for the Developer ID release pipeline. It stays in the
# keychain; callers can still select a different profile without putting credentials in Git.
NOTARY_PROFILE="${POMACE_NOTARY_PROFILE:-notarytool}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
APP="$HERE/build/Pomace.app"
DIST="$HERE/dist"
STAGING="$(mktemp -d)"
NOTARY_ZIP="$STAGING/Pomace-notarization.zip"
RELEASE_ZIP="$DIST/Pomace-$VERSION.zip"

cleanup() { rm -rf "$STAGING"; }
trap cleanup EXIT

mkdir -p "$DIST"
POMACE_VERSION="$VERSION" "$HERE/build-app.sh" release
codesign --verify --deep --strict --verbose=2 "$APP"

# The app itself receives the ticket. A ZIP cannot be stapled directly, so it is made only
# after the notarized ticket is attached to Pomace.app.
ditto -c -k --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

ditto -c -k --keepParent "$APP" "$RELEASE_ZIP"
shasum -a 256 "$RELEASE_ZIP" > "$RELEASE_ZIP.sha256"
printf 'release ZIP: %s\n' "$RELEASE_ZIP"
