# Pomace — Roadmap

**Status:** 1.1 implementation complete; manual release checks pending · **Last updated:** 2026-10-23

M0–M5 record the original milestones. The 1.1 checklist separates implemented release
tooling from the manual checks still required before publishing. Engine work moves to 1.2.

---

## M0 — Spike: prove the risky assumptions

- [x] Native detection: `lstat` `st_flags & UF_COMPRESSED` + `com.apple.decmpfs` parsing,
      against files compressed with each of ZLIB / LZVN / LZFSE
- [x] **Physical-size accuracy** — computed savings checked against `afsctool -v` across a
      varied corpus ([ADR-0002](DECISIONS.md#adr-0002-native-detection-subprocess-only-for-mutation))
- [x] **TCC inheritance** — agent and GUI have byte-identical access, and both differ
      from the launching shell. ADR-0006 holds; no daemon fallback needed.
      See [M0-FINDINGS §9](M0-FINDINGS.md#9-tcc-inheritance--adr-0006-holds)
- [x] Walk performance: FTS wins; 1.24M files in 20.26s, beating the 500k/30s target
- [x] afsctool output parsing against 1.7.3, with a captured transcript corpus
- [x] Full [SAFETY.md §5 checklist](SAFETY.md#5-m0-verification-checklist) green on a
      disposable APFS sparse image — round-trip SHA-256 stable, hard links and inodes intact
- [x] Decompression-speed measurement per compressor — LZFSE reads 33% faster than ZLIB

Sampling-estimator validation and broader tuning benchmarks remain open under 1.2 below;
the existing measurements are not general performance claims.

---

## M1 — Scan and show

- [x] SPM structure, scripted bundle, signing, entitlements ([ADR-0013](DECISIONS.md#adr-0013-no-xcodeproj--the-app-bundle-is-assembled-by-script))
- [x] `PomaceCore` scan engine: walk, cancellation, progress coalesced to 100ms
- [x] SQLite store, schema v1, WAL mode
- [x] SwiftUI shell — sidebar / content (inspector added in M2)
- [x] Directory picker — NSOpenPanel is itself the consent gesture
- [x] File table with size, physical size, and compression state
- [x] Safety-rule evaluation, with exclusions and their reasons shown inline
- [x] Aggregate summary header with coverage bar

---

## M2 — Compress and decompress

- [x] Compressor version detection and capability check (applesauce since ADR-0015)
- [x] Bundled universal applesauce and checked custom override, replacing Homebrew
      discovery and the install flow ([ADR-0017](DECISIONS.md#adr-0017-bundle-applesauce))
- [x] Auto-tuning policy engine ([DEFAULTS.md §2](DEFAULTS.md#2-policy)) with per-flag
      justification strings
- [x] Settings → Advanced pane: computed values, reasons, revert and compressor selection
- [x] Live progress, non-blocking, cancellable at batch boundaries
- [x] Decompress, beside Compress, gated by a confirmation naming the file count
- [x] Post-run native re-scan — this is what surfaced the afsctool data-loss bug
- [x] Destructive-action confirmations per [SAFETY.md §4](SAFETY.md#4-operational-rules)
- [x] Error surfaces that name the file and say what to do next

The first mutation build found a real data-loss bug: see [M2-FINDINGS](M2-FINDINGS.md)
for the afsctool hard-link bug and the two guards against it. Per-directory compressor
measurement is still deferred to 1.2; the policy accepts a measured winner but does not
yet measure one. Advanced policy override controls and `-b` backup on first run remain
deferred beyond 1.1.

---

## M3 — Watched directories

- [x] `SMAppService` agent registration and honest status reporting
- [x] Schedule editor — cadence evaluated in-process, not baked into the plist ([ADR-0014](DECISIONS.md#adr-0014-the-agent-wakes-on-a-fixed-interval-and-asks-the-store-what-is-due))
- [x] `--sweep-all` headless mode, argument dispatch before any scene is built
- [x] Precondition gating: power, thermal, Low Power Mode, Time Machine — deferrals recorded, not dropped
- [x] Incremental sweep by mtime with a grace period, plus periodic full verification
- [x] Run history persisted and shown per directory
- [x] Notifications on error only, never on routine success
- [x] Login Items state reflected honestly in the UI

---

## M4 — Polish

- [x] History timeline making drift visible over months
- [x] Menu bar item (optional, off by default)
- [x] Keyboard commands, focus and VoiceOver labels implemented
- [ ] Full keyboard navigation and VoiceOver walkthrough — complete [ACCESSIBILITY.md](ACCESSIBILITY.md)
- [ ] Light/dark, Dynamic Type, Reduce Motion and contrast verification — complete
      [ACCESSIBILITY.md](ACCESSIBILITY.md); Reduce Motion and non-color state cues are implemented
- [x] App icon
- [x] Onboarding explaining transparent compression, including the write-decompresses caveat
- [x] Eight-locale catalog and localized formatting; machine translations with
      [corrections welcome](TRANSLATING.md)

---

## M5 — Ship

- [x] Developer ID signing, hardened runtime, notarization and stapling pipeline
- [x] Notarized DMG packaging for GitHub Releases (replaces ZIP)
- [x] Sparkle updates with signed feeds and relaunch postponed through active runs
- [x] User-initiated crash reporting and redacted diagnostics; preview before sharing,
      no automatic upload
- [x] [ADR-0008](DECISIONS.md#adr-0008-gpl-30-or-later-for-pomace) — GPL-3.0-or-later
- [x] Public README, screenshots, honest description of transparent compression
- [x] CI runs `scripts/gate.sh`: Swift/Cargo tests, bundled helper, sparse-image integration,
      universal bundle, localization, release dry-run and permission-aware AX checks

Signing and notarization tooling is implemented. Creating and publishing the real 1.1
release remain explicit maintainer actions after the checks below.

## 1.1 release checklist

- [ ] Clean user account without Homebrew: compress and decompress disposable files
- [ ] Local Sparkle update rc1→rc2 using `python3 -m http.server`; verify the sweep agent afterwards
- [ ] Complete the VoiceOver and keyboard checklist in [ACCESSIBILITY.md](ACCESSIBILITY.md)
- [ ] **PENDING confirmation AX verification:** run `scripts/check-ax.swift` with an unlocked
      GUI and AX permission; verify AXDefaultButton=Cancel and Return/Escape dismissal,
      then fill the accessibility checklist rows
- [ ] Review locale screenshots for all eight languages, including long strings and clipping
- [ ] Intel Mac: launch, scan, compress/decompress a disposable folder and check for updates

An automated `check-ax` skip (no AX permission or unlocked GUI session) does not complete
these manual checks. See [release/README.md](../release/README.md) for release and publishing.

## 1.2 — Smarter compression

- [ ] Sampling-estimator accuracy check: compare predicted and actual savings; redesign
      if error exceeds ±15% before presenting an estimate
- [ ] Per-directory compressor measurement ([ADR-0010](DECISIONS.md#adr-0010-choose-the-compressor-by-measuring-the-directory-not-by-static-default))
- [ ] FSEvents-driven sweeps (compress on arrival, not just on schedule)
- [ ] Re-run tuning benchmarks with cold cache, repeated runs, varied corpora, external
      media and Intel; see [DEFAULTS.md §6](DEFAULTS.md#6-what-m0-must-re-measure)

## Deferred beyond 1.1

- Archive mode (`afsctool -a`/`-x`)
- Multi-volume management, external drive awareness
- Per-file-type compression policies
- Scriptability — `NSUserActivity`, Shortcuts actions, a `pomace` CLI
- Advanced policy overrides and `-b` backup on first run
