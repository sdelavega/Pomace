#!/bin/bash
# Measures DECOMPRESSION (read) throughput per compressor — the cost users pay on every
# read, and the gap DEFAULTS.md §6 flagged as never measured.
# Uses hdiutil detach/attach between runs to evict the volume's buffer cache, which is the
# closest we can get to a cold read without sudo purge.
set -eu
IMG="${1:?usage: decomp-bench.sh <image-path-without-extension>}"
VOL=/Volumes/PomaceM0

reattach() {   # drops cached blocks for this volume
  hdiutil detach "$VOL" -quiet -force 2>/dev/null || true
  sleep 1
  hdiutil attach "$IMG.sparseimage" -nobrowse -quiet
  sleep 1
}

read_all() {   # returns seconds to read every byte
  local dir="$1"
  python3 - "$dir" <<'PY'
import sys, os, time
root = sys.argv[1]
paths = []
for dp, _, fns in os.walk(root):
    for fn in fns:
        p = os.path.join(dp, fn)
        if os.path.isfile(p) and not os.path.islink(p): paths.append(p)
t0 = time.time(); total = 0
for p in paths:
    try:
        with open(p, 'rb') as f:
            while True:
                b = f.read(1 << 20)
                if not b: break
                total += len(b)
    except OSError: pass
dt = time.time() - t0
print(f"{dt:.3f} {total}")
PY
}

echo "=== decompression / read throughput, cold cache (detach+reattach between runs) ==="
printf "%-12s %10s %12s %12s\n" "compressor" "read(s)" "bytes" "MB/s"

for T in NONE ZLIB LZVN LZFSE; do
  rm -rf "$VOL/dbench"; mkdir -p "$VOL/dbench"
  cp -R "$VOL/corpus/text" "$VOL/dbench/" 2>/dev/null
  cp -R "$VOL/corpus/binary" "$VOL/dbench/" 2>/dev/null
  cp -R "$VOL/corpus/edge" "$VOL/dbench/" 2>/dev/null
  rm -f "$VOL/dbench/edge/sparse-10mb.bin"          # excluded: see SAFETY findings
  if [ "$T" != "NONE" ]; then
    afsctool -c -T "$T" -J4 -S -f "$VOL/dbench" >/dev/null 2>&1
  fi
  sync; reattach
  out=$(read_all "$VOL/dbench")
  dt=$(echo "$out" | cut -d' ' -f1); by=$(echo "$out" | cut -d' ' -f2)
  mbs=$(python3 -c "print(f'{$by/1e6/$dt:.1f}')")
  printf "%-12s %10s %12s %12s\n" "$T" "$dt" "$by" "$mbs"
done
rm -rf "$VOL/dbench"
echo DONE
