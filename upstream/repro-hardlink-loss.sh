#!/bin/bash
# Minimal reproduction: afsctool destroys hard-linked file contents.
#
# Creates hard-linked files in a temporary directory, compresses them, and reports how many
# were truncated to zero bytes. Touches nothing outside its own temp directory.
#
#   ./repro-hardlink-loss.sh [path-to-afsctool]
set -u
AFSCTOOL="${1:-$(command -v afsctool)}"
[ -x "$AFSCTOOL" ] || { echo "afsctool not found; pass its path as the first argument"; exit 1; }

SETS=10
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "afsctool: $AFSCTOOL"
"$AFSCTOOL" 2>&1 | head -1
echo "volume:   $(df -h "$WORK" | tail -1 | awk '{print $1}')  ($(diskutil info "$(df "$WORK" | tail -1 | awk '{print $1}')" 2>/dev/null | awk -F: '/Personality/{print $2}' | xargs))"
echo

make_corpus() {
  rm -rf "$WORK/c"; mkdir -p "$WORK/c"
  for i in $(seq 1 $SETS); do
    yes "hard linked content" | head -5000 > "$WORK/c/s${i}-a.txt"   # 100,000 bytes
    ln "$WORK/c/s${i}-a.txt" "$WORK/c/s${i}-b.txt"
    ln "$WORK/c/s${i}-a.txt" "$WORK/c/s${i}-c.txt"
  done
}

destroyed() {
  local n=0
  for i in $(seq 1 $SETS); do
    [ "$(stat -f %z "$WORK/c/s${i}-a.txt")" != "100000" ] && n=$((n + 1))
  done
  echo $n
}

trial() {
  local label="$1" target="$2"; shift 2
  make_corpus
  if [ "$target" = dir ]; then
    "$AFSCTOOL" -c "$@" "$WORK/c" >/dev/null 2>&1
  else
    "$AFSCTOOL" -c "$@" "$WORK"/c/*.txt >/dev/null 2>&1
  fi
  printf "  %-34s %2d / %d destroyed\n" "$label" "$(destroyed)" "$SETS"
}

echo "MODE A — directory walk without -f"
trial "afsctool -c <dir>"            dir
trial "afsctool -c -S <dir>"         dir -S
trial "afsctool -c -f <dir>"         dir -f

echo
echo "MODE B — explicit file list at one thread"
trial "afsctool -c -f <files>"       files -f
trial "afsctool -c -J1 -f <files>"   files -J1 -f
trial "afsctool -c -j1 -f <files>"   files -j1 -f

echo
echo "MODE C — explicit file list at two threads (intermittent; re-run to see it vary)"
trial "afsctool -c -J2 -S -f <files>" files -J2 -S -f
trial "afsctool -c -J4 -S -f <files>" files -J4 -S -f

echo
echo "WORKAROUND — one path per inode, at the worst setting"
make_corpus
"$AFSCTOOL" -c -J1 -S -f "$WORK"/c/s*-a.txt >/dev/null 2>&1
printf "  %-34s %2d / %d destroyed" "one path per inode, -J1" "$(destroyed)" "$SETS"
echo "   (siblings: $(stat -f %Sf "$WORK/c/s1-b.txt"))"
