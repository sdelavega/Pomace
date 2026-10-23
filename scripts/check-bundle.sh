#!/bin/bash
# Validate the assembled app before it is shipped or used by later gates.
set -euo pipefail

fail() {
  echo "bundle check failed: $*" >&2
  exit 1
}

UNIVERSAL=0
if [ "${1:-}" = "--universal" ]; then
  UNIVERSAL=1
  shift
fi
[ "$#" -eq 1 ] || fail "usage: scripts/check-bundle.sh [--universal] <app>"
APP="$1"
[ -d "$APP" ] || fail "app bundle missing: $APP"
HELPER="$APP/Contents/Helpers/applesauce"
BINARY="$APP/Contents/MacOS/Pomace"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
PLIST="$APP/Contents/Info.plist"

[ -x "$HELPER" ] || fail "missing executable helper: Contents/Helpers/applesauce"
[ -x "$BINARY" ] || fail "missing executable app: Contents/MacOS/Pomace"
[ -d "$FRAMEWORK" ] || fail "missing Sparkle.framework"

check_universal() {
  local archs
  archs="$(lipo -archs "$1")" || fail "cannot read architectures: $2"
  case " $archs " in
    *" arm64 "*) ;;
    *) fail "missing arm64 architecture: $2" ;;
  esac
  case " $archs " in
    *" x86_64 "*) ;;
    *) fail "missing x86_64 architecture: $2" ;;
  esac
}

if [ "$UNIVERSAL" -eq 1 ]; then
  if LC_ALL=C grep -a -q 'PomaceUITestFixture' "$BINARY"; then
    fail "release binary contains PomaceUITestFixture debug hook"
  fi
  check_universal "$BINARY" "Contents/MacOS/Pomace"
  check_universal "$HELPER" "Contents/Helpers/applesauce"
  check_universal "$FRAMEWORK/Sparkle" "Sparkle.framework/Sparkle"
fi
SPARKLE_VERSION="$FRAMEWORK/Versions/B"
for component in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
  codesign --verify --strict "$SPARKLE_VERSION/$component" || fail "invalid Sparkle component signature: $component"
done
codesign --verify --strict "$FRAMEWORK" || fail "invalid Sparkle signature"
echo "Sparkle signed: framework and nested helpers verified"
codesign --verify --strict "$HELPER" || fail "invalid helper signature"
codesign --verify --strict "$APP" || fail "invalid app signature"
"$HELPER" --version || fail "helper --version failed"

for key in SUFeedURL SUPublicEDKey SURequireSignedFeed SUVerifyUpdateBeforeExtraction SUEnableAutomaticChecks SUScheduledCheckInterval SUEnableSystemProfiling; do
  /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 || fail "missing Info.plist key: $key"
done

echo "bundle check passed: $APP"
