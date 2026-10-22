# Bundled applesauce

Pomace's separate binary crate packages the GPL-3.0-or-later CLI from
[Dr-Emann/applesauce, applesauce-cli-v0.5.30](https://github.com/Dr-Emann/applesauce/releases/tag/applesauce-cli-v0.5.30).
`src/main.rs` and `src/progress.rs` are copied unchanged from Tesserae's wrapper:
verbatim upstream files with provenance and GPL notices prepended. The package
is named `pomace-applesauce`; the executable remains `applesauce`. Consequently
`--version` prints `pomace-applesauce 0.5.30`.

The CLI's direct dependencies and features match upstream, with exact versions
from that tag's Cargo.lock. The applesauce library comes from crates.io.
Cargo.lock pins the complete dependency graph. This crate builds separately
from the SwiftPM package. Its own deny.toml permits GPL-3 and its dependency
licences. `scripts/gate.sh` audits the helper licences with cargo-deny.

Build with `scripts/build-applesauce.sh`: both macOS architectures, macOS 14
minimum, `--locked`, and an ad-hoc hardened runtime signature. The output is
`build/applesauce`. `Tests/integration/sparse-image.sh` uses it by default;
`POMACE_COMPRESSOR` can select another executable for the disposable-image test.

To upgrade, choose an upstream release tag, replace both source files verbatim
while preserving the provenance/GPL prefix, and update the package version,
features and exact dependency versions from that tag's CLI manifest and lock.
Seed Cargo.lock from upstream, resolve the local crate, and review any changes.
Run the helper tests, the licence check and `scripts/gate.sh`. Recheck --verify
support and the scratch-volume measurements before shipping.
