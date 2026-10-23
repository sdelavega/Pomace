#!/bin/bash
# Publish only artifacts bound to this source commit by the release manifest.
set -euo pipefail
cd "$(dirname "$0")/.."
fail() { echo "$*" >&2; exit 1; }
[ "$#" = 1 ] || fail 'usage: publish.sh VERSION'
VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail 'VERSION must be x.y.z'
DMG="dist/Pomace-$VERSION.dmg"
NOTES="release/$VERSION.md"
[ -f "$DMG" ] && [ -f dist/MANIFEST ] || fail 'Missing release artifacts'
SHA="$(shasum -a 256 "$DMG")"
SHA="${SHA%% *}"
[ -s dist/appcast.xml ] && [ -s "$NOTES" ] || fail 'Missing appcast or release notes'
python3 release/metadata.py verify "$VERSION" "$(git rev-parse HEAD)" "$SHA"
TOOLS="$(pwd)/build/sparkle-tools/bin"
bash release/release-tools.sh --check "$TOOLS"
python3 release/metadata.py check-feed "$VERSION" "$DMG" dist/appcast.xml 0 build/Pomace.app "$TOOLS/sign_update"
[ -n "${POMACE_TAP_DIR:-}" ] || fail 'Set POMACE_TAP_DIR to the tap clone'
TAP="$POMACE_TAP_DIR"
PAGES="$(pwd)/dist/.publish-pages-$VERSION"
[ ! -e "$PAGES" ] || fail 'Pages worktree path already exists; inspect it before retrying'

run() {
  if [ "${POMACE_PUBLISH_FAKE:-0}" = 1 ]; then
    printf '%q ' "$@"
    printf '\n'
  else
    "$@"
  fi
}

render_cask() { python3 release/metadata.py cask "$VERSION" "$SHA" > "$1"; }
if [ "${POMACE_PUBLISH_FAKE:-0}" != 1 ]; then
  [ -z "$(git status --porcelain)" ] || fail 'Publish requires a clean tree'
  [ -z "$(git -C "$TAP" status --porcelain --untracked-files=all)" ] || fail 'Tap must be clean'
  [ "$(git -C "$TAP" rev-parse --show-toplevel)" = "$(cd "$TAP" && pwd)" ] || fail 'Tap must be a repository root'
  case "$(git -C "$TAP" remote get-url origin)" in
    https://github.com/sdelavega/homebrew-tap|https://github.com/sdelavega/homebrew-tap.git|git@github.com:sdelavega/homebrew-tap.git|ssh://git@github.com/sdelavega/homebrew-tap.git) ;;
    *) fail 'Tap origin must be sdelavega/homebrew-tap' ;;
  esac
  git show-ref --verify --quiet "refs/tags/v$VERSION" && fail 'Release tag already exists'
fi

# Every publishing mutation, including filesystem and local Git changes, uses run.
run git tag -a "v$VERSION" -m "Pomace $VERSION"
run git push origin "refs/tags/v$VERSION"
run gh release create "v$VERSION" "$DMG" --verify-tag --notes-file "$NOTES" \
  --title "Pomace $VERSION" --repo sdelavega/Pomace
run git fetch origin +refs/heads/gh-pages:refs/remotes/origin/gh-pages
run git worktree add --detach "$PAGES" origin/gh-pages
cleanup() {
  if [ -d "$PAGES" ]; then run git worktree remove "$PAGES"; fi
}
trap cleanup EXIT
run cp dist/appcast.xml "$PAGES/appcast.xml"
run git -C "$PAGES" add appcast.xml
run git -C "$PAGES" -c commit.gpgsign=false commit -m "Release v$VERSION appcast"
run git -C "$PAGES" push origin HEAD:refs/heads/gh-pages
run mkdir -p "$TAP/Casks"
run render_cask "$TAP/Casks/pomace.rb"
run git -C "$TAP" add Casks/pomace.rb
run git -C "$TAP" -c commit.gpgsign=false commit -m "Pomace $VERSION"
run git -C "$TAP" push origin HEAD
