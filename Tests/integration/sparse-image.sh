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

cd "$ROOT"
POMACE_COMPRESSOR="${POMACE_COMPRESSOR:-build/applesauce}"
case "$POMACE_COMPRESSOR" in
  /*) ;;
  *) POMACE_COMPRESSOR="$ROOT/$POMACE_COMPRESSOR" ;;
esac
if [ ! -f "$POMACE_COMPRESSOR" ] || [ ! -x "$POMACE_COMPRESSOR" ]; then
  echo "Compressor is missing or not executable: $POMACE_COMPRESSOR (run scripts/build-applesauce.sh)" >&2
  exit 1
fi
export POMACE_COMPRESSOR

mkdir "$MOUNT"
hdiutil create -size 3g -fs APFS -volname PomaceIntegration "$IMAGE" -quiet
hdiutil attach "$IMAGE" -mountpoint "$MOUNT" -nobrowse -quiet
ATTACHED=1

"$ROOT/spikes/make-corpus.sh" "$MOUNT/corpus"
cd "$ROOT"
swift run pomace-spike engine-verify "$MOUNT/corpus" | tee "$TMP/engine-verify.log"
if ! grep -Fqx "applesauce: $POMACE_COMPRESSOR (a location you chose)" "$TMP/engine-verify.log"; then
  echo "engine-verify did not use the selected compressor: $POMACE_COMPRESSOR" >&2
  exit 1
fi
