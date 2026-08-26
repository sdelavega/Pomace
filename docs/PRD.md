# Pomace — Product Requirements

**Status:** Draft · **Last updated:** 2026-08-26

## 1. Problem

macOS has supported transparent filesystem compression since 10.6. Almost nobody uses it,
because the available command-line tools are difficult to assess and run safely:

- The CLI's choices have real consequences, with little guidance about safe defaults.
- A compression pass over a large directory takes tens of minutes with no progress output
  and no safe way to interrupt it.
- Afterwards, you cannot easily tell what state your disk is in — which files compressed,
  which were skipped, how much you actually saved.
- **Compression drifts.** Writing to a compressed file transparently decompresses it. New
  files arrive uncompressed. A directory compressed once decays continuously, invisibly.

Point 4 is the one no existing tool addresses, on any platform. It is Pomace's reason to exist.

## 2. Users

- **Primary:** developers and power users with large write-once/read-many directories on a
  space-constrained internal SSD — game libraries, downloaded datasets, VM base images,
  archived project trees, `node_modules` graveyards, media libraries.
- **Secondary:** anyone who has read that afsctool exists, tried it once, and was
  reasonably unwilling to run it on a directory they care about.

**Not a target:** server operators, anyone wanting an archive format, anyone wanting
compression on non-Apple filesystems.

## 3. Goals

| # | Goal | Success looks like |
|---|---|---|
| G1 | Make the outcome visible *before* mutating anything | Every compress action is preceded by a scan showing per-file and total estimated savings |
| G2 | Keep watched directories compressed over time | A directory added in January is still >95% compressed in June with no user action |
| G3 | Feel like an Apple app | Passes an honest side-by-side with a first-party utility. No web view. |
| G4 | Remove the install barrier | A user with no Homebrew and no `applesauce` reaches a working first scan without opening Terminal |
| G5 | Never lose or corrupt data | Zero data-loss reports. Verification on by default. |

## 4. Non-goals

- **Not cross-platform.** The entire feature set is Apple-filesystem-specific.
- **Not an archiver.** Pomace works only with transparent filesystem compression, never a
  private archive format.
- **Not a disk analyzer.** Pomace shows sizes in service of compression decisions. It is
  not DaisyDisk and won't grow into it.
- **Not Mac App Store distributable.** See [ADR-0004](DECISIONS.md#adr-0004-non-sandboxed-developer-id-distribution).
- **Not a filesystem driver.** Pomace never writes `decmpfs` attributes itself; all
  mutation goes through `applesauce`.

## 5. Features

### 5.1 Scan (P0)

Point Pomace at a directory. It walks the tree and reports, without modifying anything:

- Total logical size, total physical size, current reclaimed bytes
- Per-file compression state: uncompressed / ZLIB / LZVN / LZFSE, and which storage
  (inline xattr vs resource fork)
- Files excluded by safety rules, each with the reason ([SAFETY.md](SAFETY.md))
- Estimated additional savings if compressed at the selected algorithm and level

Scans must be cancellable, show live progress, and remain responsive on trees of 500k+
files. Results are cached so reopening a known directory is instant.

**Estimation approach:** exact prediction requires actually compressing. v1 samples — it
compresses a bounded number of representative blocks per file type in memory and
extrapolates by extension cohort. The UI must present this as an estimate with a range,
never as a promise. Post-compression, real figures replace estimates.

### 5.2 Compress / Decompress (P0)

- **No compression options in the default path.** Algorithm, level, and threshold are
  computed. See [DEFAULTS.md](DEFAULTS.md).
- Intent expressed, if at all, as *Automatic / Maximum savings / Fastest* in the directory
  inspector — never as individual flags.
- Every flag remains reachable per-directory in Settings → Advanced, each showing its
  computed value and the reason for it ([ADR-0009](DECISIONS.md#adr-0009-progressive-disclosure--automatic-by-default-every-flag-reachable)).
- Verification on by default (`--verify` is required).
- Live progress: current file, files done / total, bytes reclaimed so far, throughput, ETA.
- **Cancellable at a file boundary** — never mid-file.
- Decompress is a first-class, equally prominent action. Anything Pomace does, it can undo.

### 5.3 Watched directories (P0 — the differentiating feature)

Register a directory as watched, with a schedule:

- **Cadence:** daily / weekly / monthly at a chosen time, or on an interval.
- **Trigger mode:** scheduled sweep (v1), with filesystem-event-driven sweeps as a v2 option.
- **Per-directory settings:** algorithm, level, min-savings threshold, exclusions —
  remembered so re-sweeps are consistent with the original pass.

The background agent must be a good citizen:

- Low-priority I/O and background scheduling class; never competes with foreground work.
- Skips the sweep when: on battery, in Low Power Mode, under elevated thermal pressure, or
  while a Time Machine backup is running.
- Missed windows (machine asleep) are picked up at the next opportunity, not skipped silently.
- Every sweep writes a run record: started, duration, files touched, bytes reclaimed, errors.

### 5.4 History (P1)

A per-directory timeline: every scan and sweep, what changed, cumulative bytes reclaimed.
This is what makes drift legible — the user should be able to see "this directory decayed
8% last month" and understand why the watching feature is earning its keep.

### 5.5 Compressor management (P0)

On launch, locate `applesauce`. Resolution order:

1. A path the user explicitly configured
2. `/opt/homebrew/bin/applesauce`, `/usr/local/bin/applesauce`
3. Pomace's private copy in `~/Library/Application Support/Pomace/bin/`
4. `PATH`

If absent, offer to install via `brew install Dr-Emann/homebrew-tap/applesauce`. Always
explain what will be installed, from where, and that it is GPL-licensed third-party software.
Never install silently.

Verify the discovered binary before first use: run it, parse the version, confirm it
supports the flags Pomace intends to pass. Surface a version mismatch rather than failing
mid-sweep.

### 5.6 Menu bar item (P2)

Optional status item: sweep in progress, last sweep result, quick access to watched
directories.

## 6. Interface sketch

Standard `NSSplitView` three-pane, matching Finder / Mail / System Settings conventions:

- **Sidebar:** Watched Directories, plus a Recent Scans section.
- **Content:** for a selected directory — a header with the savings summary and primary
  actions, over an outline view of the tree with per-item size, physical size, state, and
  estimated savings.
- **Inspector (optional, toggleable):** settings for the selected directory — algorithm,
  threshold, schedule, exclusions.

Progress belongs inline in the content header, not in a modal sheet. A long compression run
must not block the window; the user should be free to scan another directory while one
compresses.

## 7. Constraints

- **macOS 14+** (settled in M1 — see [ADR-0012](DECISIONS.md#adr-0012-macos-14-deployment-floor)).
  `SMAppService` needs only 13, but `@Observable` needs 14 and is worth it.
- Non-sandboxed, Developer ID signed, notarized.
- TCC still applies: Desktop, Documents, Downloads, iCloud Drive, network and removable
  volumes each require user consent even for a non-sandboxed app. Full Disk Access is the
  pragmatic ask for the background agent; the onboarding flow must explain why.
- Never require Terminal for any supported flow.

## 8. Open questions

- **Q1.** Is estimation-by-sampling accurate enough to be useful, or does it need to be
  replaced by a real bounded trial compression? → resolve in the M0 spike. Now doubly
  load-bearing, since [ADR-0010](DECISIONS.md#adr-0010-choose-the-compressor-by-measuring-the-directory-not-by-static-default)
  also uses sampling to pick the compressor.
- **Q2.** Should watched-directory sweeps compress *new* files only, or re-verify the whole
  tree? Whole-tree is correct but expensive on large directories. Likely: incremental by
  mtime with a periodic full verification.
- **Q3.** How should Pomace handle a watched directory that disappears — external volume
  unmounted, folder moved? Track by inode where possible; degrade gracefully.
- **Q4.** Which `applesauce` release becomes Pomace's minimum supported version?
