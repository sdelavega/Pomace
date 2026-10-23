#!/bin/bash
# Project checks in dependency order. Later tasks append their gates here.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTUP_TOOLCHAIN=stable

swift test
scripts/build-applesauce.sh
cargo test --manifest-path tools/applesauce/Cargo.toml --locked
cargo deny --manifest-path tools/applesauce/Cargo.toml --config tools/applesauce/deny.toml check licenses
Tests/integration/sparse-image.sh
./build-app.sh release
scripts/check-bundle.sh --universal build/Pomace.app
python3 -m unittest discover -s release/tests
release/release.sh 0.0.0-dryrun --dry-run
python3 -m unittest discover -s scripts/tests
python3 scripts/check-l10n.py lint
python3 scripts/check-l10n.py catalog --locales en zh-Hans es ja ko de fr pt-BR
./build-app.sh debug
swiftc scripts/check-ax.swift -o build/check-ax
build/check-ax
