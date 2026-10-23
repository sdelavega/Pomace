# Pomace — Architecture

**Status:** Implemented for 1.1; manual release checks pending · **Last updated:** 2026-10-23

## 1. Processes and bundle

SwiftPM builds the Swift 6 app and shared core. `build-app.sh` assembles the bundle;
there is no Xcode project ([ADR-0013](DECISIONS.md#adr-0013-no-xcodeproj--the-app-bundle-is-assembled-by-script)).
Release builds are universal arm64 + x86_64 with a macOS 14 deployment floor. Debug
builds use the host architecture.

```text
Pomace.app/Contents/
├── MacOS/Pomace                         GUI or headless sweep driver
├── Helpers/applesauce                   pinned universal Rust compressor
├── Frameworks/Sparkle.framework/        updater, XPC services and nested helpers
├── Library/LaunchAgents/
│   └── com.sdelavega.Pomace.Sweep.plist
├── Resources/Pomace_PomaceApp.bundle/    processed localization resources
└── Info.plist
```

The same app executable handles GUI mode, `--sweep <id>` and `--sweep-all`.
Argument dispatch happens before building scenes. Headless runs use `.prohibited`
activation and never create the Sparkle updater. GUI and scheduled scans share the
app's TCC identity ([ADR-0006](DECISIONS.md#adr-0006-scheduled-sweeps-re-launch-the-main-binary-headless)).
Only mutation is delegated to applesauce. An explicitly confirmed administrator run
can elevate that compressor; scans, the GUI and scheduled sweeps remain unprivileged.

`build-app.sh` embeds Sparkle 2.10.0 and the bundled helper, then signs inside-out:
Sparkle XPC services (preserving entitlements), Autoupdate, Updater.app, the framework,
applesauce, and the app. Developer ID builds use hardened runtime and timestamps;
local builds without the identity use ad-hoc signatures. No signing uses `--deep`.
Before release signing, the script removes SwiftPM's absolute Xcode and cryptexd
toolchain rpaths from the distribution binary. System `/usr/lib/` paths and
bundle-relative rpaths remain. `scripts/check-bundle.sh --universal` rejects absolute
non-system rpaths in the app, helper and Sparkle executables, and checks architectures,
signatures, updater plist keys and absence of the debug UI fixture.

## 2. Modules and presentation

- `Sources/PomaceCore/`: native scanning, safety rules, compressor resolution and
  invocation, policy, scheduling, SQLite storage, `SweepLock`, diagnostics and redaction.
- `Sources/PomaceApp/`: SwiftUI views, `ScanModel`, AppKit integration, argument dispatch,
  Sparkle, diagnostics collection and localized presentation.
- `Sources/pomace-spike/`: command-line probes and integration-test entry points.
- `tools/applesauce/`: separately locked Cargo wrapper, pinned to applesauce `=0.8.10`.
- `Tests/PomaceCoreTests/` and `Tests/PomaceAppTests/`: Swift Testing suites.

PomaceCore has no SwiftUI or AppKit dependency. User-facing outcomes are typed values:
`SafetyReason`, runtime constraints, policy justifications, warnings, deferrals and
engine errors. App-side `CoreText` maps these to stable catalog keys; `AppStrings`
formats interpolations and locale-aware bytes, counts, dates and durations. Enum raw
values stored in SQLite or UserDefaults remain persistence keys, including values
written by 1.0.2. Display translations do not change them.

The processed `Localizable.xcstrings` catalog ships English, Simplified Chinese,
Spanish, Japanese, Korean, German, French and Brazilian Portuguese. Translations are
machine-made; [corrections are welcome](TRANSLATING.md). Logs and maintainer-facing
diagnostic reports stay English.

## 3. Native scanning

`DirectoryWalker.walkFTS` walks the tree with native stat data. `FileInspector` reads
`UF_COMPRESSED` and the `com.apple.decmpfs` header, passing `XATTR_SHOWCOMPRESSION`
so compressed attributes are visible. Detection never launches the compressor.

Physical size depends on storage: resource-fork payloads use allocated blocks;
inline payloads use the decmpfs attribute length rather than interpreting zero data
blocks as zero physical size. Unknown compression types remain visibly compressed
with an unknown algorithm. Byte totals deduplicate hard-linked inodes; table row
identity is the path so distinct links remain distinct rows.

`ScanEngine` runs the walk off the main actor, streams progress at most every 0.1 s,
and caps retained detail at 200,000 entries. Aggregate totals still cover the whole
tree. Stream termination cancels the task; scans check cancellation during the walk.
Safety exclusions are attached as typed reasons. Adding or scanning a folder does
not authorize recurring mutation.

## 4. Compressor resolution and mutation

`CompressorTool.resolve` checks the custom path in Settings → Advanced first, then
the bundled `Contents/Helpers/applesauce`. A custom choice must resolve to a regular,
executable file at an absolute path and pass the capability probe. The bundled copy
must also have a valid code signature. Every usable compressor supports LZFSE,
verification and minimum-ratio control. There is no Homebrew or PATH discovery and
no installed private copy ([ADR-0017](DECISIONS.md#adr-0017-bundle-applesauce)).

Resolution happens again at each run. If a custom choice becomes unusable, normal
runs fall back to the checked bundled copy and the UI shows the rejection. If neither
is usable, scanning remains available and mutation is disabled. For administrator
runs, the confirmation binds the resolved path and SHA-256; a changed path or bytes
refuses the run before authorization. The hash must be stable across capability probing.
The privileged script copies the binary into a root-owned mode-700 temporary directory,
checks the confirmed hash, and executes only that copy across batches, rechecking source
and copy hashes between batches. Cleanup precedes the final outcome; denied cleanup or
process death may leave the private temporary copy behind.

Administrator targets must pass the same directory-chain preflight without privilege
and again as root immediately before each batch: physical containment, regular non-symlink
file, link count one, and root-owned directories without group/world write access or ACLs.
The check includes root ancestors and rejects symlinked components. User-owned Homebrew
trees cannot use elevation. `cd -P`/`pwd -P` supplies physical parent paths; the bundled
wrapper and library stay unchanged. See ADR-0016 for the threat boundary.

The engine emits the actual per-run `CompressorResolution`, including rejection or
unavailability. `ScanModel` consumes it for UI and reports. Before invocation the engine
rebuilds argv through `CompressionPolicy` for the fresh capabilities, preserving the
chosen savings threshold and mandatory verification when an algorithm must fall back.

Every compress argv contains `--verify`. Explicit batches are sorted smallest-first,
and Stop waits for the active batch to finish safely. Hard links and other unsafe
files are excluded before invocation. Compressor output is diagnostic: native
post-run inspection determines each file's result, and a fresh scan supplies the
persisted and displayed before/after totals. Decompression requires confirmation
naming the affected file count.

## 5. Scheduling and update interlock

`SMAppService.agent(plistName: "com.sdelavega.Pomace.Sweep.plist")` registers the
bundled LaunchAgent. `BundleProgram` points to `Contents/MacOS/Pomace`; the app works
outside a fixed installation path. `StartInterval=3600` wakes `--sweep-all` hourly.
Per-directory cadence, preferred hour and mode live in SQLite, so changing a schedule
does not rewrite the signed plist ([ADR-0014](DECISIONS.md#adr-0014-the-agent-wakes-on-a-fixed-interval-and-asks-the-store-what-is-due)).

The short-lived background process checks what is due, records deferrals for system
conditions such as power, thermal state and Time Machine, and incrementally scans
changed files with periodic full verification. Its launchd job uses Background process
priority, low-priority I/O and Nice 10. Registration status reflects `SMAppService`
state, including disabled or approval-required states. Normal successes do not notify.

`SweepLock` uses a nonblocking exclusive `flock` at
`~/Library/Application Support/Pomace/sweep.lock`. GUI compression/decompression and
headless sweeps hold it for the run, excluding a second mutation process. Every exit
releases it. The GUI releases the lock before publishing its final state, so a
finished or refused state cannot still leave the updater observing an active run.

`Updates` wraps Sparkle's `SPUStandardUpdaterController`. Signed appcast and update
verification use the committed public EdDSA key; the private key stays in the
maintainer's keychain. Automatic checks default to daily; system profiling is off.
The app menu and General settings expose manual and automatic checks. Before allowing
Sparkle's relaunch handoff, `Updates` acquires an exclusive `SweepLock` and retains it for
the GUI process lifetime. If a run holds it, poll every five seconds until acquisition
succeeds, then invoke the install handler with the reservation still held. New GUI runs
and agent sweeps cannot enter during this handoff. `willInstallUpdateOnQuit` records a
staged update; the SwiftUI AppKit delegate returns `terminateLater` until it can hold the
same reservation, then replies to the termination request. Agent registration is
re-validated after launch.

Sparkle 2.10.0's pinned `SPUUpdaterDelegate.h` says the relaunch-postponement callback is
not called if the user did not relaunch on the previous update, and may be skipped when
installation will not relaunch the app. A staged install-on-quit still uses Pomace's
termination reservation. A path that bypasses both hooks, forced termination, or an
external installer cannot be postponed by this protocol; an active run is not guaranteed
to drain there. The reservation ends when the GUI exits and does not span the helper's
subsequent replacement/relaunch. The locally served rc1→rc2 installation remains a manual
pre-release check; automated tests exercise the pinned delegate and termination handoff
with real file locks, without installing or terminating the app.

## 6. Persistence and permissions

`Store` uses the SQLite C API with WAL mode, foreign keys, a serial queue and a busy
timeout for GUI/agent access. Schema v2 holds watched directories and schedules,
aggregate scan snapshots and sweep history. Per-file scan rows are held in memory,
not persisted. Settings such as the custom compressor path also use UserDefaults.

```text
~/Library/Application Support/Pomace/
├── pomace.sqlite             plus SQLite WAL/SHM files when open
├── sweep.lock
└── Logs/                    MutationLog files
```

The app is not sandboxed, but macOS privacy controls still gate protected user
folders and volumes. The GUI's folder picker is the scan-consent gesture. Background
access depends on the same app's grants; the UI reports registration and access
failures rather than promising that registration alone gives disk access. See
[SAFETY.md](SAFETY.md) for exclusions and administrator-run boundaries.

## 7. Accessibility and diagnostics

Views expose labels, values and hints for custom coverage, history, state and progress
content. Keyboard commands and focus order are explicit. Reduce Motion suppresses
decorative animation and state is conveyed with text as well as color. Destructive
confirmations have one default action, Cancel, with an Escape handler for dismissal.
The live AX verification of default Cancel and Return/Escape remains pending in
[ACCESSIBILITY.md](ACCESSIBILITY.md).

Help → Report a Problem collects app/build, OS and architecture, compressor source and
version, agent status, recent sweep history, the last 500 lines of each relevant
MutationLog file (GUI and agent if separate), and Pomace `.ips` crash reports from the
last 30 days. MutationLog files are the actual log source; Pomace has no OSLog producer.

`DiagnosticsReport` passes the complete report through `Redactor`: home becomes `~`,
paths below known roots become numbered folders, volume names are hidden,
and usernames, host names and temporary paths are removed, including paths in crash
JSON. The collected log/crash windows can outlive current sidebar roots and the last
20 sweep records. Unknown home paths therefore retain only their first component
(`~/Documents/<path>`); unknown volume paths become `/Volumes/<volume>/<path>`.
This conservative fallback also covers removed manual folders and evicted history roots. The user previews the redacted report before Copy, Save As… or Open GitHub Issue.
The issue URL has a length budget and adds an attachment note on truncation. No report
is uploaded automatically.

## 8. Validation and distribution

`scripts/gate.sh` is the local and macOS CI entry point: Swift tests, universal helper
build, locked Cargo tests and license checks, the complete disposable APFS sparse-image
round trip, universal app and bundle validation, release-script tests and a release
dry-run, script tests, localization lint/catalog checks, and a debug build for AX checks.
`check-ax` skips without AX permission or an unlocked GUI session; a skip leaves the
manual accessibility pass outstanding.

The release dry-run uses ad-hoc signing and a throwaway OpenSSL Ed25519 key; it needs
no secrets or Python packages and skips the clean-tree check and nested gate call.
Real releases require a clean tree and the gate, build a signed/notarized/stapled DMG,
and generate a signed appcast. `CFBundleVersion` is `major*10000 + minor*100 + patch`
(each component 0–99); `POMACE_BUILD` supports increasing release-candidate builds.
Publishing is a separate explicit step. See [release/README.md](../release/README.md).

Automated checks do not complete the clean-account, local Sparkle rc1→rc2, VoiceOver
and keyboard, locale screenshot or Intel Mac runtime checks. Those remain open in the
[1.1 release checklist](ROADMAP.md#11-release-checklist). Savings-estimator validation,
ADR-0010 per-directory measurement and FSEvents are 1.2 work.
