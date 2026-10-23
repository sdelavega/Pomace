#!/bin/bash
# Fetch and verify the pinned Sparkle executables before running any of them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

check_tools() {
  local directory="$1"
  if ! (cd "$directory" && shasum -a 256 -c "$ROOT/release/sparkle-tools.sha256"); then
    echo 'Sparkle tool checksum mismatch' >&2
    return 1
  fi
}

prepare_tools() {
  local directory="$ROOT/build/sparkle-tools"
  if [ ! -d "$directory/bin" ]; then
    mkdir -p "$directory"
    curl --fail --location --retry 2 --output "$directory/Sparkle-2.10.0.tar.xz" \
      https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz
    tar -xJf "$directory/Sparkle-2.10.0.tar.xz" -C "$directory" bin/generate_appcast bin/sign_update bin/generate_keys
  fi
  check_tools "$directory/bin"
  TOOLS="$directory/bin"
}

fetch_appcast() {
  local status=0
  if git ls-remote --exit-code origin refs/heads/gh-pages >/dev/null; then
    git fetch origin +refs/heads/gh-pages:refs/remotes/origin/gh-pages
    git show origin/gh-pages:appcast.xml > "$1"
  else
    status=$?
    [ "$status" = 2 ] || return "$status"
    : > "$1"
  fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "$#" = 2 ] && [ "$1" = --check ]; then
    check_tools "$2"
  elif [ "$#" = 0 ]; then
    prepare_tools
  else
    echo 'usage: release-tools.sh [--check DIRECTORY]' >&2
    exit 1
  fi
fi
