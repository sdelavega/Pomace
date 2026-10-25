# Releasing Pomace

Releasing has two separate steps: build and verify the DMG, then explicitly publish it.
Run both from the same clean source commit. `dist/` is ignored scratch space.

## One-time maintainer setup

- Install the Developer ID Application certificate in the login keychain. Set
  `POMACE_SIGN_ID` to its SHA-1 identity hash (keep local identity details out of Git).
- Store notarization credentials interactively with
  `xcrun notarytool store-credentials "Pomace Notary"`. Follow its prompts; never put
  credentials in scripts or command arguments. To reuse an existing profile for the
  same Developer ID team instead, set `POMACE_NOTARY_PROFILE` to its name.
- Keep the existing Sparkle key for account `Pomace` in the login keychain. Its public
  key is in `Resources/Info.plist`. Do not generate a replacement key for a release.
- Initialize and push an orphan `gh-pages` branch containing an empty RSS appcast
  (`<rss version="2.0"><channel><title>Pomace</title></channel></rss>` in `appcast.xml`).
  In GitHub Settings → Pages, choose Deploy from a branch, `gh-pages`, root directory.
  The feed URL is `https://sdelavega.github.io/Pomace/appcast.xml`.
- Authenticate GitHub CLI for `sdelavega/Pomace`. Clone `sdelavega/homebrew-tap`, keep
  the clone clean, and set `POMACE_TAP_DIR=~/src/homebrew-tap` to that repository root.
- Commit release notes as `release/X.Y.Z.md`. Notes support plain paragraphs, `#`
  headings and `-` bullet lists; the release script renders them to escaped HTML.

## Build and verify

```bash
release/release.sh 1.1.0
```

Real mode requires a clean tree, runs `scripts/gate.sh`, builds the universal app with
Developer ID signing, and checks the bundle. It creates a UDZO disk image with an
Applications shortcut, signs and notarizes it using `Pomace Notary` (or `POMACE_NOTARY_PROFILE`), staples and
validates it, then assesses the DMG and mounted app with Gatekeeper. Mounts are inside
an ignored temporary directory and are detached on exit.

`build-app.sh` sets CFBundleVersion from `POMACE_VERSION` as
`major * 10000 + minor * 100 + patch`; every component must be 0–99. For example,
1.1.0 becomes 10100. `POMACE_BUILD` overrides the numeric build for release-candidate
update tests. A non-x.y.z version such as 0.0.0-dryrun defaults to build 1. Feed
validation requires the item's build and marketing versions to match the bundle,
and verifies the DMG and feed signatures using that bundle's public key.

Sparkle 2.10.0 is downloaded to `build/sparkle-tools/`. All three executable hashes
must match `release/sparkle-tools.sha256` before use; cached mismatches fail rather
than being silently replaced. Appcast generation uses a fresh directory containing
only the current DMG, HTML notes and the feed fetched from `origin/gh-pages`. A missing
remote branch means an empty feed; other fetch errors fail. Deltas are disabled and
historical items are retained. The DMG and feed signatures are verified against the
committed public key. Successful output is `dist/Pomace-X.Y.Z.dmg`, `dist/appcast.xml`
and JSON `dist/MANIFEST` (`version`, `commit`, `dmg_sha256`, `appcast_sha256`, `dry_run`).
The appcast hash binds the exact signed feed bytes that passed release validation.

For a local rehearsal without publishing or accessing the real Sparkle key:

```bash
release/release.sh 0.0.0-dryrun --dry-run
```

Dry-run skips the clean-tree check and gate (the gate itself calls it), Developer ID
signing, notarization, stapling and Gatekeeper assessment. It uses ad-hoc signatures,
a mode-0600 temporary random Ed25519 seed and an empty feed, producing exactly one
item. Dry-run requires an `openssl` with Ed25519 support on PATH (for example,
Homebrew OpenSSL); macOS's older system LibreSSL may lack it. No third-party Python
packages are needed. OpenSSL generates a temporary keypair; only the staged DMG app
gets its public key before ad-hoc signing. `POMACE_SIGN_ADHOC=1` explicitly selects
ad-hoc signing in build-app.sh and skips signing-identity lookup. The dry run uses
the 1.1.0 notes for the gate's synthetic version. It never runs
`generate_keys`, reads the login keychain's Sparkle key, or fetches the published feed.
The temporary key is removed on exit. Its manifest is marked `dry_run: true` and is
refused by publishing; only a fresh real release build can produce shipping proof.

## Gate and release readiness

CI runs `scripts/gate.sh` on a GitHub macOS runner with `permissions: contents: read`.
It installs Rust stable with both Darwin targets and `cargo-deny`; the Rust tools in
`~/.cargo/bin` take precedence over Homebrew. Every third-party action is pinned by
full commit SHA. The gate needs no signing or notarization secrets: CI explicitly
uses ad-hoc signing, explicitly installs the major-pinned Homebrew `openssl@3` formula
and prepends its bin directory to PATH, and downloads/hash-checks Sparkle 2.10.0 tools.
`metadata.py` reports the Ed25519-capable OpenSSL requirement clearly if OpenSSL is
missing or cannot generate the disposable key. The gate's dry-run does not publish anything.

The universal bundle check validates signatures, architectures and updater keys,
rejects debug hooks, and rejects absolute rpaths outside `/usr/lib/` in the shipped
executables. `build-app.sh release` removes absolute Xcode/cryptexd toolchain rpaths
before signing, keeping system and bundle-relative paths. The gate later builds a
debug app for `check-ax`, which skips if AX permission or an unlocked GUI session is
unavailable. A skip is not evidence that the manual accessibility pass succeeded.

Before a real release, complete the [1.1 release checklist](../docs/ROADMAP.md#11-release-checklist):
clean-account testing without Homebrew, a locally served Sparkle rc1→rc2 update,
VoiceOver/keyboard checks (including the pending confirmation AXDefaultButton=Cancel
and Return/Escape verification), locale screenshots and an Intel Mac run. Give each
candidate an increasing `POMACE_BUILD`; the normal 1.1.0 build is 10100, following
1.0.2's build 1. Users of 1.0.2 install 1.1 manually once because 1.0.2 has no updater.

Help → Report a Problem supplies user-initiated diagnostics: recent MutationLog file
lines and sweep history, plus Pomace crash reports from the last 30 days. The user
previews the redacted report and chooses whether to share it; there is no automatic
crash upload. Report collection does not depend on OSLog.

## Publish after reviewing the artifacts

```bash
POMACE_PUBLISH_FAKE=1 release/publish.sh 1.1.0
release/publish.sh 1.1.0
```

The first command prints the plan without running publishing commands. Both validate
the requested version, HEAD commit, DMG SHA-256 and appcast SHA-256 against the manifest
first, and refuse dry-run artifacts. They also check the pinned Sparkle tool hashes and
re-run `check-feed` with `build/Pomace.app`: the feed and enclosure signatures, selected
release/build, download URL, length, deployment floor and release notes must pass before
any publishing mutation. Keep the matching build bundle and pinned tools alongside the
release artifacts. A changed feed, missing release, invalid signature or wrong enclosure
is refused even in fake mode. Review the DMG, feed and notes before invoking real mode.
Real mode tags and pushes `vX.Y.Z`, creates the GitHub release with DMG and notes,
commits/pushes the appcast through a detached `gh-pages` worktree, then renders,
commits and pushes `Casks/pomace.rb` in `POMACE_TAP_DIR`. Every mutation goes through
`run()`, which only prints when `POMACE_PUBLISH_FAKE=1`.

Publishing can stop after a remote step has succeeded. Inspect the tag, release,
Pages branch and tap before recovering manually; there is no automatic resume mode.
Never edit the manifest to repair mismatched artifacts. Rebuild from the intended
commit instead. No CI publishing workflow is installed by this pipeline.
