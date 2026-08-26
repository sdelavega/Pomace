#!/bin/bash
# Builds the M0 test corpus on an attached test volume.
# Covers every case in docs/SAFETY.md §5.
set -eu
ROOT="${1:?usage: make-corpus.sh <dir>}"
mkdir -p "$ROOT"/{text,binary,edge,media,bundle}

# --- compressible text (resource-fork storage path) ---
for i in $(seq 1 40); do
  yes "lorem ipsum dolor sit amet consectetur adipiscing elit $i" | head -8000 > "$ROOT/text/doc$i.txt"
done

# --- real binaries (mixed compressibility) ---
cp /bin/[a-z]* "$ROOT/binary/" 2>/dev/null || true
cp /usr/lib/libSystem.B.dylib "$ROOT/binary/" 2>/dev/null || true
chmod -R u+w "$ROOT/binary" 2>/dev/null || true

# --- incompressible: real random data, some disguised as media ---
dd if=/dev/urandom of="$ROOT/media/random1.bin" bs=1m count=8 2>/dev/null
dd if=/dev/urandom of="$ROOT/media/photo.jpg"   bs=1m count=4 2>/dev/null
dd if=/dev/urandom of="$ROOT/media/clip.mp4"    bs=1m count=6 2>/dev/null

# --- edge cases ---
: > "$ROOT/edge/zero-byte.txt"                                  # 0 bytes
printf 'x%.0s' $(seq 1 100)   > "$ROOT/edge/tiny-100b.txt"      # inline-xattr path
printf 'y%.0s' $(seq 1 2000)  > "$ROOT/edge/small-2k.txt"
yes "big file padding line for the large file test" | head -400000 > "$ROOT/edge/large-20mb.txt"

# hard links: three paths, one inode
yes "hard linked content" | head -5000 > "$ROOT/edge/hardlink-a.txt"
ln "$ROOT/edge/hardlink-a.txt" "$ROOT/edge/hardlink-b.txt"
ln "$ROOT/edge/hardlink-a.txt" "$ROOT/edge/hardlink-c.txt"

# symlinks: valid and dangling
ln -s "$ROOT/text/doc1.txt" "$ROOT/edge/symlink-valid"
ln -s "/nonexistent/target" "$ROOT/edge/symlink-dangling"

# sparse file: 10 MB logical, ~0 allocated
dd if=/dev/zero of="$ROOT/edge/sparse-10mb.bin" bs=1 count=0 seek=10485760 2>/dev/null

# pre-existing resource fork
yes "data fork content" | head -2000 > "$ROOT/edge/has-rsrc.txt"
printf 'PRE-EXISTING RESOURCE FORK PAYLOAD' > "$ROOT/edge/has-rsrc.txt/..namedfork/rsrc"

# read-only file
yes "read only content" | head -3000 > "$ROOT/edge/readonly.txt"
chmod 444 "$ROOT/edge/readonly.txt"

# file with unicode / spaces in name
yes "unicode name test" | head -1000 > "$ROOT/edge/née café — test.txt"

# --- a signed app bundle, for the codesign check ---
for candidate in /System/Applications/Utilities/Activity\ Monitor.app \
                 /System/Applications/Calculator.app \
                 /System/Applications/Stickies.app; do
  if [ -d "$candidate" ]; then
    cp -R "$candidate" "$ROOT/bundle/" 2>/dev/null && break
  fi
done
chmod -R u+w "$ROOT/bundle" 2>/dev/null || true

echo "corpus built at $ROOT"
find "$ROOT" -type f | wc -l | xargs echo "  regular files:"
find "$ROOT" -type l | wc -l | xargs echo "  symlinks:     "
du -sh "$ROOT" | cut -f1 | xargs echo "  size:         "
