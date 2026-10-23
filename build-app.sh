#!/bin/bash
# Assembles Pomace.app from the SPM build. There is no .xcodeproj by design — the bundle is
# scripted so it is reproducible and reviewable in a diff (ADR-0013).
#
# Signing identity: sign by SHA-1 hash, not name. Two identical "Developer ID Application"
# certificates in different keychains make --sign by name ambiguous, and codesign then
# produces a BROKEN signature while reporting success.
#   security find-identity -v -p codesigning
set -euo pipefail
CONFIG="${1:-debug}"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/build/Pomace.app"
IDENTITY="${POMACE_SIGN_ID:-85E7645225011373853E0C0F50CF9967974BB7BE}"
VERSION="${POMACE_VERSION:-}"

cd "$HERE"
source "$HERE/scripts/lib/rpaths.sh"
BUILD_VERSION="$(python3 release/metadata.py build-number "$VERSION" "${POMACE_BUILD:-}")"
BUILD_ARGS=(-c "$CONFIG" --product PomaceApp)
# CI can explicitly exercise SwiftPM's native system without changing its default.
if [ -n "${POMACE_SWIFT_BUILD_SYSTEM:-}" ]; then
  BUILD_ARGS+=(--build-system "$POMACE_SWIFT_BUILD_SYSTEM")
fi

echo "building ($CONFIG)…"
if [ "$CONFIG" = "release" ]; then
  # Multiple --arch flags select XCBuild, which cannot run our build-tool plugin.
  # Single-arch builds compile the catalog before we combine only the executables.
  BINS=()
  RESOURCE_BUNDLE=""
  for arch in arm64 x86_64; do
    swift build "${BUILD_ARGS[@]}" --arch "$arch"
    PRODUCTS_DIR="$(swift build "${BUILD_ARGS[@]}" --arch "$arch" --show-bin-path)"
    ARCH_RESOURCE_BUNDLE="$PRODUCTS_DIR/Pomace_PomaceApp.bundle"
    if [ ! -d "$ARCH_RESOURCE_BUNDLE" ]; then
      echo "missing processed SwiftPM resource bundle: $ARCH_RESOURCE_BUNDLE" >&2
      exit 1
    fi
    # Some SwiftPM systems reuse a products directory for successive architectures.
    # Preserve both outputs before the next build can overwrite either of them.
    ARCH_STAGE="$HERE/build/release-$arch"
    rm -rf "$ARCH_STAGE"
    mkdir -p "$ARCH_STAGE"
    cp "$PRODUCTS_DIR/PomaceApp" "$ARCH_STAGE/PomaceApp"
    cp -R "$ARCH_RESOURCE_BUNDLE" "$ARCH_STAGE/"
    BINS+=("$ARCH_STAGE/PomaceApp")
    ARCH_RESOURCE_BUNDLE="$ARCH_STAGE/Pomace_PomaceApp.bundle"
    if [ -z "$RESOURCE_BUNDLE" ]; then
      RESOURCE_BUNDLE="$ARCH_RESOURCE_BUNDLE"
    elif ! diff -rq "$RESOURCE_BUNDLE" "$ARCH_RESOURCE_BUNDLE"; then
      echo "architecture resource bundles differ" >&2
      exit 1
    fi
  done
  mkdir -p "$HERE/build"
  BIN="$HERE/build/PomaceApp-universal"
  lipo -create "${BINS[@]}" -output "$BIN"
else
  swift build "${BUILD_ARGS[@]}"
  BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/PomaceApp"
  PRODUCTS_DIR="$(dirname "$BIN")"
  RESOURCE_BUNDLE="$PRODUCTS_DIR/Pomace_PomaceApp.bundle"
  if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "missing processed SwiftPM resource bundle: $RESOURCE_BUNDLE" >&2
    exit 1
  fi
fi

SPARKLE_SOURCE=""
for candidate in "$HERE/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework"/macos-*/Sparkle.framework; do
  if [ -d "$candidate" ]; then
    SPARKLE_SOURCE="$candidate"
    break
  fi
done
if [ -z "$SPARKLE_SOURCE" ]; then
  echo "missing macOS Sparkle.framework artifact" >&2
  exit 1
fi

if [ ! -f "$HERE/build/applesauce" ] || [ "$HERE/tools/applesauce/Cargo.lock" -nt "$HERE/build/applesauce" ]; then
  "$HERE/scripts/build-applesauce.sh"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents" "$APP/Contents/Helpers" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Pomace"
if [ "$CONFIG" = "release" ]; then
  # SwiftPM embeds build-host toolchain paths in both slices. Strip only those paths
  # from the distribution copy, before signing; keep system and bundle-relative paths.
  RPATHS="$(macho_rpaths "$APP/Contents/MacOS/Pomace" | sort -u)"
  while IFS= read -r rpath; do
    case "$rpath" in
      /Applications/Xcode.app*|/var/run/com.apple.security.cryptexd*|/Library/Developer/CommandLineTools/*)
        install_name_tool -delete_rpath "$rpath" "$APP/Contents/MacOS/Pomace"
        ;;
    esac
  done <<< "$RPATHS"
fi
cp "$HERE/build/applesauce" "$APP/Contents/Helpers/applesauce"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/Resources/Pomace.icns" "$APP/Contents/Resources/Pomace.icns"
# SwiftPM keeps processed localization resources beside the executable rather than in it.
# Copy the bundle into the application so `Bundle.module` resolves after distribution.
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
ditto "$SPARKLE_SOURCE" "$FRAMEWORK"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" "$APP/Contents/Info.plist"
# The scheduled-sweep agent ships inside the bundle so it is covered by the signature and
# removed cleanly when the app is deleted (ADR-0005).
cp "$HERE/Resources/com.sdelavega.Pomace.Sweep.plist" "$APP/Contents/Library/LaunchAgents/"

SIGN_ARGS=(--force --options runtime --sign -)
APP_SIGN_ARGS=(--force --sign -)
if [ "${POMACE_SIGN_ADHOC:-0}" = 1 ]; then
  SIGNING_DESCRIPTION="ad-hoc signed (requested)"
elif security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  SIGN_ARGS=(--force --options runtime --timestamp --sign "$IDENTITY")
  APP_SIGN_ARGS=("${SIGN_ARGS[@]}" --entitlements "$HERE/Resources/Pomace.entitlements")
  SIGNING_DESCRIPTION="signed with Developer ID"
else
  # Ad-hoc app signatures omit library validation so a local build can load Sparkle.
  SIGNING_DESCRIPTION="ad-hoc signed (Developer ID identity not found)"
fi

# Sparkle's manual signing order, preserving the services' shipped entitlements:
# https://sparkle-project.org/documentation/sandboxing/#code-signing
SPARKLE_VERSION="$FRAMEWORK/Versions/B"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Installer.xpc"
codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SPARKLE_VERSION/XPCServices/Downloader.xpc"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_VERSION/Autoupdate"
codesign "${SIGN_ARGS[@]}" "$SPARKLE_VERSION/Updater.app"
codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
codesign "${SIGN_ARGS[@]}" "$APP/Contents/Helpers/applesauce"
codesign "${APP_SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$APP"
echo "$SIGNING_DESCRIPTION"
echo "built: $APP"
