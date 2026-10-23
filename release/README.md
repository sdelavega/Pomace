# Releasing Pomace

Releasing has two separate steps: build and verify the DMG, then explicitly publish it.
Run both from the same clean source commit. `dist/` is ignored scratch space.

## One-time maintainer setup

- Install the Developer ID Application certificate in the login keychain. Set
  `POMACE_SIGN_ID` to its SHA-1 identity hash (keep local identity details out of Git).
- Store notarization credentials interactively with
  `xcrun notarytool store-credentials "Pomace Notary"`. Follow its prompts; never put
  credentials in scripts or command arguments.
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
Applications shortcut, signs and notarizes it using `Pomace Notary`, staples and
validates it, then assesses the DMG and mounted app with Gatekeeper. Mounts are inside
an ignored temporary directory and are detached on exit.

Sparkle 2.10.0 is downloaded to `build/sparkle-tools/`. All three executable hashes
must match `release/sparkle-tools.sha256` before use; cached mismatches fail rather
than being silently replaced. Appcast generation uses a fresh directory containing
only the current DMG, HTML notes and the feed fetched from `origin/gh-pages`. A missing
remote branch means an empty feed; other fetch errors fail. Deltas are disabled and
historical items are retained. The DMG and feed signatures are verified against the
committed public key. Successful output is `dist/Pomace-X.Y.Z.dmg`, `dist/appcast.xml`
and JSON `dist/MANIFEST` (`version`, `commit`, `dmg_sha256`, `dry_run`).

For a local rehearsal without publishing or accessing the real Sparkle key:

```bash
release/release.sh 0.0.0-dryrun --dry-run
```

Dry-run skips the clean-tree check and gate (the gate itself calls it), Developer ID
signing, notarization, stapling and Gatekeeper assessment. It uses ad-hoc signatures,
a mode-0600 temporary random Ed25519 seed and an empty feed, producing exactly one
item. Dry-run requires Python's `cryptography` package to derive the temporary public
key, which replaces the public key only in the staged DMG app before ad-hoc signing. It uses the 1.1.0 notes for the gate's synthetic version. It never runs
`generate_keys`, reads the login keychain's Sparkle key, or fetches the published feed.
The temporary key is removed on exit. Its manifest is marked `dry_run: true` and is
refused by publishing; only a fresh real release build can produce shipping proof.

## Publish after reviewing the artifacts

```bash
POMACE_PUBLISH_FAKE=1 release/publish.sh 1.1.0
release/publish.sh 1.1.0
```

The first command prints the plan without running publishing commands. Both validate
the requested version, HEAD commit and DMG SHA-256 against the manifest first, and
refuse dry-run artifacts. Review the DMG, feed and notes before invoking real mode.
Real mode tags and pushes `vX.Y.Z`, creates the GitHub release with DMG and notes,
commits/pushes the appcast through a detached `gh-pages` worktree, then renders,
commits and pushes `Casks/pomace.rb` in `POMACE_TAP_DIR`. Every mutation goes through
`run()`, which only prints when `POMACE_PUBLISH_FAKE=1`.

Publishing can stop after a remote step has succeeded. Inspect the tag, release,
Pages branch and tap before recovering manually; there is no automatic resume mode.
Never edit the manifest to repair mismatched artifacts. Rebuild from the intended
commit instead. No CI publishing workflow is installed by this pipeline.
