#!/bin/bash
set -u
BASE="$(pwd)"; BIG="$BASE/bigcorpus"
if [ ! -d "$BIG" ]; then
  mkdir -p "$BIG"
  for i in 1 2 3 4 5 6; do cp -R "$BASE/corpus" "$BIG/c$i" 2>/dev/null; done
  chmod -R u+w "$BIG" 2>/dev/null
fi
echo "big corpus: $(du -sh "$BIG"|cut -f1), $(find "$BIG" -type f|wc -l|tr -d ' ') files"; echo
phys(){ find "$1" -type f -exec stat -f "%b" {} + | awk '{s+=$1} END {print s*512}'; }
logi(){ find "$1" -type f -exec stat -f "%z" {} + | awk '{s+=$1} END {print s}'; }
run(){ local label="$1"; shift; local dir="$BASE/r2"
  rm -rf "$dir"; cp -R "$BIG" "$dir" 2>/dev/null
  local L0; L0=$(logi "$dir")
  local t0 t1; t0=$(python3 -c 'import time;print(time.time())')
  afsctool -c "$@" "$dir" >/dev/null 2>&1
  t1=$(python3 -c 'import time;print(time.time())')
  local P1; P1=$(phys "$dir")
  python3 - "$label" "$L0" "$P1" "$t0" "$t1" <<'PY'
import sys
l,L0,P1,t0,t1=sys.argv[1],int(sys.argv[2]),int(sys.argv[3]),float(sys.argv[4]),float(sys.argv[5])
dt=t1-t0
print(f"{l:<26} saved={100.0-(P1/L0*100):5.1f}%  time={dt:6.1f}s  thru={L0/1e6/dt:6.1f} MB/s")
PY
  rm -rf "$dir"; }
echo "=== thread scaling, LZFSE, larger corpus ==="
for t in 1 2 4 6 8 10; do run "LZFSE -J$t" -T LZFSE -J$t -S -f; done
echo
echo "=== -j vs -J at 4 ==="
run "LZFSE -j4 (IO exclusive)" -T LZFSE -j4 -S -f
run "LZFSE -J4 (IO concurrent)" -T LZFSE -J4 -S -f
echo
echo "=== ZLIB level curve (-J4) ==="
for l in 1 5 9; do run "ZLIB -$l" -T ZLIB -$l -J4 -S -f; done
echo DONE
