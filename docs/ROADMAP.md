# Pomace — Roadmap

**Status:** Draft · **Last updated:** 2026-08-26

Six milestones. M0 exists to kill the project cheaply if its assumptions are wrong — do not
skip it or build UI in parallel with it.

---

## M0 — Spike: prove the risky assumptions

**No UI. Command-line test harness only.** Every item here is something the whole design
rests on and none of it is confirmed yet.

- [x] Native detection: `lstat` `st_flags & UF_COMPRESSED` + `com.apple.decmpfs` parsing,
      against files compressed with each of ZLIB / LZVN / LZFSE
- [x] **Physical-size accuracy** — do our computed savings agree with `afsctool -v` across a
      varied corpus? ([ADR-0002](DECISIONS.md#adr-0002-native-detection-subprocess-only-for-mutation))
- [x] **TCC inheritance** — confirmed: agent and GUI have byte-identical access, and both
      differ from the launching shell. ADR-0006 holds; no daemon fallback needed.
      See [M0-FINDINGS §9](M0-FINDINGS.md#9-tcc-inheritance--adr-0006-holds)
- [x] Walk performance: FTS wins; 1.24M files in 20.26s, beating the 500k/30s target
- [x] afsctool output parsing against 1.7.3, with a captured transcript corpus
- [ ] Savings estimation by sampling — measure predicted vs. actual error. If it's worse
      than ±15%, redesign the estimator now rather than after it's wired into the UI.
- [x] Full [SAFETY.md §5 checklist](SAFETY.md#5-m0-verification-checklist) green on a
      disposable APFS sparse image — round-trip SHA-256 stable, hard links and inodes intact
- [ ] **Re-run the tuning benchmarks properly** — cold cache, repeated runs, multiple corpora,
      external media, Intel fallback. Full list in [DEFAULTS.md §6](DEFAULTS.md#6-what-m0-must-re-measure).
      The current numbers chose our defaults but are not shippable claims.
- [x] Decompression-speed measurement per compressor — LZFSE reads 33% faster than ZLIB

**Exit criteria:** every box checked, or an ADR written explaining the change of plan.

---

## M1 — Scan and show

First build that's worth looking at. Read-only — it cannot modify anything yet, which makes
it safe to run on real directories while the engine is still young.

- [x] SPM structure, scripted bundle, signing, entitlements ([ADR-0013](DECISIONS.md#adr-0013-no-xcodeproj--the-app-bundle-is-assembled-by-script))
- [x] `PomaceCore` scan engine: walk, cancellation, progress coalesced to 100ms
- [x] SQLite store, schema v1, WAL mode
- [x] SwiftUI shell — sidebar / content (inspector deferred to M2, when there are settings to put in it)
- [x] Directory picker — NSOpenPanel is itself the consent gesture
- [x] File table with size, physical size, and compression state
- [x] Safety-rule evaluation, with exclusions and their reasons shown inline
- [x] Aggregate summary header with coverage bar

---

## M2 — Compress and decompress

- [x] Tool discovery, version detection, capability check (applesauce since ADR-0015)
- [x] Install flow — Homebrew tap with the licence disclosure (direct download deferred)
- [x] Auto-tuning policy engine ([DEFAULTS.md §2](DEFAULTS.md#2-policy)) with per-flag
      justification strings
- [ ] Per-directory compressor measurement ([ADR-0010](DECISIONS.md#adr-0010-choose-the-compressor-by-measuring-the-directory-not-by-static-default)) — **deferred to M2.1**, the policy engine accepts a measured winner but nothing measures yet
- [x] Settings → Advanced pane: computed values, reasons, revert (override controls deferred)
- [x] Live progress, non-blocking, cancellable at batch boundaries
- [x] Decompress, beside Compress, gated by a confirmation naming the file count
- [x] Post-run native re-scan — this is what surfaced the afsctool data-loss bug
- [x] Destructive-action confirmations per [SAFETY.md §4](SAFETY.md#4-operational-rules)
- [x] Error surfaces that name the file and say what to do next

**This is the first build that can destroy data.** It found a real one: see
[M2-FINDINGS](M2-FINDINGS.md) for the afsctool hard-link bug and the two guards against it.

Deferred out of M2: per-directory compressor measurement ([ADR-0010](DECISIONS.md#adr-0010-choose-the-compressor-by-measuring-the-directory-not-by-static-default)),
override controls in the Advanced pane (it displays and reverts, but doesn't yet edit), the
direct-download install path, and `-b` backup on first run.

---

## M3 — Watched directories

The differentiating feature.

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
- [ ] Menu bar item (optional, off by default)
- [ ] Full keyboard navigation; VoiceOver pass
- [ ] Light/dark, Dynamic Type, Reduce Motion
- [ ] App icon
- [ ] Onboarding that explains transparent compression honestly, including the write-decompresses
      caveat, in about four sentences
- [ ] Localization scaffolding (strings catalog), English only at first

---

## M5 — Ship

- [ ] Developer ID signing, hardened runtime, notarization, stapling
- [ ] DMG packaging with a signed background
- [ ] Update mechanism (Sparkle, or check-and-notify)
- [ ] Crash reporting
- [ ] [ADR-0008](DECISIONS.md#adr-0008-project-license-open) — **license decided**
- [ ] Public README, screenshots, honest description of what compression will and won't do
- [ ] CI: unit tests plus the sparse-image integration suite

---

## Deferred beyond v1

- FSEvents-driven sweeps (compress on arrival, not just on schedule)
- Archive mode (`afsctool -a`/`-x`)
- Multi-volume management, external drive awareness
- Per-file-type compression policies
- Scriptability — `NSUserActivity`, Shortcuts actions, a `pomace` CLI
- Compression benchmarking to recommend an algorithm per directory
