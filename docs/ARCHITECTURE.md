# Pomace — Architecture

**Status:** Draft · **Last updated:** 2026-08-26

## 1. Shape of the thing

One language (Swift 6), one code signature, one bundle. Three run modes of the *same*
executable, plus a shared core package.

```
Pomace.app
├── Contents/MacOS/Pomace              ← single binary, three modes
│   ├── (no args)      → GUI mode: SwiftUI app, .regular activation policy
│   ├── --sweep <id>   → headless mode: .prohibited activation, run one sweep, exit
│   └── --sweep-all    → headless mode: run all due sweeps, exit
├── Contents/Library/LaunchAgents/
│   └── org.pomace.Pomace.Sweep.plist   ← registered via SMAppService
└── Contents/Resources/
```

The single-binary trick is load-bearing, not a shortcut — see
[ADR-0006](DECISIONS.md#adr-0006-scheduled-sweeps-re-launch-the-main-binary-headless).
One executable means one TCC identity, so the disk-access permission the user grants the
app is the same one the background sweep runs under. A separate helper binary would need
its own grant and its own confusing prompt.

## 2. Modules

Swift Package Manager workspace, consumed by an Xcode app target.

```
Pomace/
├── Pomace.xcodeproj                 app target, signing, entitlements, packaging
├── Sources/
│   ├── PomaceApp/                   SwiftUI views, view models, window/scene plumbing
│   ├── PomaceCore/                  ← all logic lives here. No UI imports.
│   │   ├── Scanner/                 tree walk, compression-state detection
│   │   ├── Engine/                  applesauce discovery and invocation
│   │   ├── Estimation/              savings prediction
│   │   ├── Safety/                  exclusion rules (see SAFETY.md)
│   │   ├── Schedule/                SMAppService registration, sweep planning
│   │   └── Store/                   persistence
│   └── PomaceCLI/                   argument parsing, headless sweep driver
└── Tests/
    └── PomaceCoreTests/
```

`PomaceCore` must never `import SwiftUI` or `import AppKit`. It is the part that runs
under launchd with no UI attached, and it's the part that gets tested.

## 3. Scan engine

### 3.1 Detection is native, not shelled out

The single most important performance decision. Determining a file's compression state does
**not** require the compressor:

- **`st_flags & UF_COMPRESSED`** (`0x00000020`) from `lstat(2)` — definitive, and it comes
  free with the directory walk we're already doing.
- **`com.apple.decmpfs`** xattr — a 16-byte header (`fpmc` magic, then a `uint32` type and a
  `uint64` uncompressed size, both little-endian) giving the compression type. Read it only
  for files already flagged compressed.

> **[verified 2026-08-26] `XATTR_SHOWCOMPRESSION` is mandatory.** The kernel hides
> `com.apple.decmpfs` and `com.apple.ResourceFork` from ordinary `getxattr`/`listxattr`
> calls. Without the flag, `getxattr` on a compressed file returns `-1` / `ENOATTR (93)` —
> so the naive implementation silently concludes "not compressed" for every compressed file
> on the volume. The `xattr(1)` command has the same blind spot; do not use it to sanity-check
> our results. Every decmpfs read must pass `XATTR_SHOWCOMPRESSION` (`0x0020`) as the
> `options` argument.

decmpfs compression types:

| Type | Algorithm | Storage |
|---|---|---|
| 1 | none (stored) | inline xattr |
| 3 | ZLIB | inline xattr |
| 4 | ZLIB | resource fork |
| 7 | LZVN | inline xattr |
| 8 | LZVN | resource fork |
| 11 | LZFSE | inline xattr |
| 12 | LZFSE | resource fork |

Other values exist and are rare or reserved; treat unknown types as "compressed, algorithm
unknown" rather than erroring. On APFS the resource fork is itself an extended attribute
(`com.apple.ResourceFork`), so both storage classes are xattr reads.

Shelling out to a compressor per directory would mean process spawn overhead per tree,
stdout parsing, no incremental progress, and no cancellation. Native detection gives us all
four for free.

### 3.2 Physical size: `st_blocks` is only half right

**[verified 2026-08-26]** The rule depends on where the payload was stored, and getting it
wrong produces confidently wrong savings figures:

| Storage | Types | Physical size rule |
|---|---|---|
| Resource fork | 4, 8, 12 | `st_blocks * 512` — **correct**, the fork is accounted for |
| Inline xattr | 1, 3, 7, 11 | `st_blocks` is **0**. Must use the decmpfs xattr length. |

Measured: a 2.2 MB text file compressed to the resource fork reported `st_blocks = 24`
(12288 bytes), matching afsctool exactly. A 1600-byte file compressed *inline* reported
`st_blocks = 0`, which naively reads as "100% saved, occupies nothing."

Note that **afsctool has this same blind spot** — it prints `File size (compressed): 0 bytes`
for the inline case. Pomace should be more accurate than the tool it wraps: for inline
storage, physical size is the decmpfs xattr's own length plus allocation overhead.

This matters more than it looks. Directories of many small files are exactly where inline
storage dominates, so a naive implementation over-reports savings worst precisely where
users are most likely to point it.

### 3.3 Walk

`FTS(3)` via a thin Swift wrapper, or `FileManager.enumerator` with
`.producesRelativePathURLs` and a prefetched key set. FTS is likely faster on large trees
and gives `stat` data without a second syscall; benchmark both in M0.

Concurrency: Swift 6 structured concurrency. A producer task walks directories and feeds an
`AsyncStream` of batches; a bounded pool of consumer tasks reads xattrs. Batch results back
to the main actor — never one UI update per file, or the main thread becomes the bottleneck
on a 500k-file tree. Target: a progress update at most every ~100ms.

Cancellation is cooperative via `Task.checkCancellation()` at batch boundaries.

## 4. Compression engine

Mutation — and *only* mutation — goes through `applesauce` as a subprocess.

### 4.1 Invocation

`Process` with `stdout`/`stderr` pipes, reading incrementally. A representative compress:

```
applesauce compress --compression lzfse -r <ratio> --verify <path>
```

Flag policy, enforced in code, not left to the UI:

- **`--verify` is always passed.** Post-compression verification is non-negotiable.
- **Decompression requires explicit confirmation** naming the affected path count.
- Hard-linked files are excluded before invocation because Applesauce refuses them.
- Pomace sorts its own explicit batches smallest-first; Applesauce manages parallelism itself.

### 4.2 Result verification

Applesauce reports aggregate results and may exit successfully after skipping individual
paths. Pomace therefore treats native post-run inspection as the per-file verdict; tool
output is diagnostic only.

### 4.3 Post-run truth

After any mutation, re-run a native scan of the affected subtree. That result — not
the compressor's summary — is what's persisted and displayed. It's the same code path that
produced the "before" numbers, so before/after are directly comparable.

## 5. Scheduling

### 5.1 Registration

`SMAppService.agent(plistName: "org.pomace.Pomace.Sweep.plist")`, with the plist inside
`Contents/Library/LaunchAgents/`. Registering shows the user a Login Items entry they can
disable — correct and expected; the UI should reflect `service.status` rather than assuming
registration succeeded.

Key plist entries:

```xml
<key>ProgramArguments</key>
<array>
  <string>/Applications/Pomace.app/Contents/MacOS/Pomace</string>
  <string>--sweep-all</string>
</array>
<key>StartCalendarInterval</key>   <!-- populated per user schedule -->
<key>ProcessType</key><string>Background</string>
<key>LowPriorityIO</key><true/>
<key>Nice</key><integer>10</integer>
```

`ProcessType: Background` puts the job in a throttled scheduling class; `LowPriorityIO`
keeps it off the foreground I/O path. Both matter — an unthrottled compression sweep is
extremely noticeable.

Rewriting `StartCalendarInterval` when schedules change means unregister → rewrite →
register. Handle the failure modes: user disabled the login item, plist malformed,
`.requiresApproval` status.

**Why launchd and not cron:** cron entries don't survive sleep windows, have no per-user
session context, no throttling classes, no I/O priority, and no way for the app to observe
their state. See [ADR-0005](DECISIONS.md#adr-0005-launchd-via-smappservice-not-cron).

### 5.2 Sweep logic

On `--sweep-all` the process:

1. Sets `.prohibited` activation policy — no Dock icon, no window, ever.
2. Checks preconditions: AC power, not Low Power Mode, `thermalState` ≤ `.fair`, no Time
   Machine backup running. Any failure → record "deferred", reason, exit 0.
3. Takes an `NSProcessInfo` activity assertion so the sweep isn't napped mid-file.
4. For each due directory: incremental scan → compress what drifted → record the run.
5. Exits. The agent process is short-lived by design; nothing stays resident.

Never notify on a routine successful sweep. Notify on errors, and on a directory that has
failed repeatedly.

## 6. Persistence

`~/Library/Application Support/Pomace/`

```
pomace.sqlite        watched dirs, settings, scan snapshots, run history
bin/applesauce        private copy, when not using Homebrew's
Logs/
```

SQLite (via GRDB, or raw C API to stay dependency-free — decide in M0). Not Core Data,
not SwiftData: the GUI and the headless sweep are **separate processes** hitting the same
store concurrently, which needs WAL mode and honest transaction discipline. SwiftData has
no story for cross-process access.

Schema sketch: `watched_directory`, `scan_snapshot`, `file_state` (per snapshot),
`sweep_run`, `error_log`. `file_state` is the big table — index on
`(snapshot_id, path)` and expect to prune old snapshots aggressively.

## 7. Permissions

Non-sandboxed does **not** mean unrestricted. TCC gates Desktop, Documents, Downloads,
iCloud Drive, network volumes, and removable media independently.

- Trigger the consent prompt from the GUI, in context, when a directory is first added —
  not in a permissions wall at launch.
- For the background agent, Full Disk Access is the pragmatic ask. Explain the reason in
  plain language and deep-link to the right System Settings pane.
- **Verify early.** The assumption that a launchd-spawned instance of the same binary
  inherits the app's TCC grants is *probably* right and is exactly the kind of thing that
  isn't. This is the highest-risk unknown in the design — prove it in M0 before building
  scheduling on top of it. Fallback if it fails: a `SMAppService.daemon` privileged helper,
  which is materially more work.

## 8. Testing

- **`PomaceCore` unit tests** — detection against fixture files with known decmpfs states,
  safety-rule evaluation, and compressor capability detection.
- **Integration** — a disposable sparse disk image (`hdiutil create -fs APFS`) as scratch
  space. Compress, verify byte-identical reads, decompress, verify again. This is the test
  that matters; run it in CI.
- **Corpus** — a checked-in generator producing a tree with known-compressible text,
  incompressible media, hard links, symlinks, sparse files, zero-byte files, and files with
  existing resource forks.
- **Snapshot tests** for savings estimation accuracy against real compression, so drift in
  the estimator is caught.
