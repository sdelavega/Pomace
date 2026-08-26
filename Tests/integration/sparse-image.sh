#!/bin/bash
# End-to-end mutation gate. All writes happen on a disposable APFS sparse image so this is
# safe to run locally and on CI against the real Applesauce binary.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
IMAGE="$TMP/PomaceIntegration.dmg"
MOUNT="$TMP/mount"
ATTACHED=0

cleanup() {
  if [ "$ATTACHED" = 1 ]; then
    hdiutil detach "$MOUNT" -quiet || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

command -v applesauce >/dev/null || {
  echo "applesauce must be installed before running this integration test" >&2
  exit 1
}

mkdir "$MOUNT"
hdiutil create -size 3g -fs APFS -volname PomaceIntegration "$IMAGE" -quiet
hdiutil attach "$IMAGE" -mountpoint "$MOUNT" -nobrowse -quiet
ATTACHED=1

"$ROOT/spikes/make-corpus.sh" "$MOUNT/corpus"
cd "$ROOT"
swift run pomace-spike engine-verify "$MOUNT/corpus"
