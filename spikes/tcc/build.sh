#!/bin/bash
# Builds and Developer ID-signs the TCC-inheritance probe (docs/M0-FINDINGS.md §9).
# NOTE: two identical "Developer ID Application" identities exist in different keychains on
# this machine, so `--sign` by name is ambiguous and silently produces a broken signature.
# Sign by SHA-1 hash instead; find yours with: security find-identity -v -p codesigning
set -eu
IDENTITY="${POMACE_SIGN_ID:-85E7645225011373853E0C0F50CF9967974BB7BE}"
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/PomaceTCCProbe.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
swiftc -O -framework ServiceManagement "$HERE/probe.swift" -o "$APP/Contents/MacOS/PomaceTCCProbe"
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/org.pomace.PomaceTCCProbe.plist" "$APP/Contents/Library/LaunchAgents/"
codesign --force --deep --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP" && echo "signed OK: $APP"
codesign -dv "$APP" 2>&1 | grep -E "^Identifier|^TeamIdentifier"
