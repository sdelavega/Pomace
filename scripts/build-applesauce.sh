#!/bin/bash
# Build the separately locked, pinned CLI for both macOS architectures.
set -euo pipefail
cd "$(dirname "$0")/.."
# Homebrew cargo may shadow rustup's shims.
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=stable
export MACOSX_DEPLOYMENT_TARGET=14.0

inputs=()
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  cargo build --manifest-path tools/applesauce/Cargo.toml --release --locked --target "$target"
  inputs+=("tools/applesauce/target/$target/release/applesauce")
done
mkdir -p build
lipo -create -output build/applesauce.tmp "${inputs[@]}"
codesign --force --sign - --options runtime build/applesauce.tmp
codesign --verify --strict build/applesauce.tmp
mv -f build/applesauce.tmp build/applesauce
