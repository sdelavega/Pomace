#!/bin/bash
set -u
BASE="$(pwd)"
CORPUS="$BASE/corpus"

if [ ! -d "$CORPUS" ]; then
  mkdir -p "$CORPUS"
  # mixed realistic corpus: mach-o binaries + python source/extensions
  cp -R /usr/bin "$CORPUS/bin" 2>/dev/null
  cp -R /opt/homebrew/lib/python3.14/site-packages "$CORPUS/py" 2>/dev/null
  chmod -R u+w "$CORPUS" 2>/dev/null
fi
SIZE=$(du -sk "$CORPUS" | cut -f1)
FILES=$(find "$CORPUS" -type f | wc -l | tr -d ' ')
echo "corpus: ${SIZE} KiB across ${FILES} files"
echo

phys() { find "$1" -type f -exec stat -f "%b" {} + | awk '{s+=$1} END {print s*512}'; }
logi() { find "$1" -type f -exec stat -f "%z" {} + | awk '{s+=$1} END {print s}'; }

run() {
  local label="$1"; shift
  local dir="$BASE/run_$label"
  rm -rf "$dir"; cp -R "$CORPUS" "$dir" 2>/dev/null
  local L0; L0=$(logi "$dir")
  local t0 t1
  t0=$(python3 -c 'import time;print(time.time())')
  afsctool -c "$@" "$dir" >/dev/null 2>&1
  t1=$(python3 -c 'import time;print(time.time())')
  local P1; P1=$(phys "$dir")
  python3 - "$label" "$L0" "$P1" "$t0" "$t1" <<'PY'
import sys
label, L0, P1, t0, t1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), float(sys.argv[5])
saved = 100.0 - (P1 / L0 * 100.0)
dt = t1 - t0
print(f"{label:<22} saved={saved:5.1f}%  physical={P1/1e6:8.1f} MB  time={dt:6.1f}s  thru={L0/1e6/dt:6.1f} MB/s")
PY
  rm -rf "$dir"
}

echo "=== compressor comparison (-J4 -S, sorted small-first) ==="
run "ZLIB-9  (your flags)" -T ZLIB -9 -J4 -S -f
run "ZLIB-5  (afsc default)" -T ZLIB -5 -J4 -S -f
run "LZVN"                  -T LZVN    -J4 -S -f
run "LZFSE"                 -T LZFSE   -J4 -S -f
echo
echo "=== thread scaling (LZFSE -S) ==="
run "LZFSE -J2"  -T LZFSE -J2  -S -f
run "LZFSE -J4"  -T LZFSE -J4  -S -f
run "LZFSE -J10" -T LZFSE -J10 -S -f
run "LZFSE -j4"  -T LZFSE -j4  -S -f
echo "DONE"
