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
HELPER="$APP/Contents/Helpers/applesauce"
BINARY="$APP/Contents/MacOS/Pomace"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
PLIST="$APP/Contents/Info.plist"

[ -x "$HELPER" ] || fail "missing executable helper: Contents/Helpers/applesauce"
[ -x "$BINARY" ] || fail "missing executable app: Contents/MacOS/Pomace"

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
  check_universal "$BINARY" "Contents/MacOS/Pomace"
  check_universal "$HELPER" "Contents/Helpers/applesauce"
fi
codesign --verify --strict "$HELPER" || fail "invalid helper signature"
codesign --verify --strict "$APP" || fail "invalid app signature"
"$HELPER" --version || fail "helper --version failed"

# Task 5 makes Sparkle mandatory; already validate it when embedded or requested.
if [ -d "$FRAMEWORK" ] || [ -n "${REQUIRE_SPARKLE:-}" ]; then
  [ -d "$FRAMEWORK" ] || fail "missing Sparkle.framework"
  if [ "$UNIVERSAL" -eq 1 ]; then
    check_universal "$FRAMEWORK/Sparkle" "Sparkle.framework/Sparkle"
  fi
  codesign --verify --strict "$FRAMEWORK" || fail "invalid Sparkle signature"
  for key in SUFeedURL SUPublicEDKey SURequireSignedFeed SUEnableAutomaticChecks SUScheduledCheckInterval SUEnableSystemProfiling; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$PLIST" >/dev/null 2>&1 || fail "missing Info.plist key: $key"
  done
fi

echo "bundle check passed: $APP"
