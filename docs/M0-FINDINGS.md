# M0 Spike — Findings

**Run:** 2026-08-26 · MacBook Air M5 (4P + 6E), 24 GB, macOS 27, APFS · afsctool 1.7.3
**Harness:** `Sources/pomace-spike`, `spikes/` · **Tests:** 18 passing in `Tests/PomaceCoreTests`

Verdict: **the architecture survives, with four corrections.** Three were bugs in my own
design, one is a genuine data hazard that was previously only suspected.

---

## 1. Data integrity — PASSED

Full compress → verify → decompress → verify cycle on a disposable 3 GB APFS sparse image,
124 files covering every case in [SAFETY.md §5](SAFETY.md#5-m0-verification-checklist).

```
[PASS] afsctool -c exited cleanly
[PASS] file count unchanged (124 -> 124)
[PASS] SHA-256 identical after compression (0 mismatches)
[PASS] logical size unchanged (0 mismatches)
[PASS] hard-link counts preserved (0 mismatches)
[PASS] inodes stable (0 changed)
[INFO] 118/124 files now carry UF_COMPRESSED
[PASS] afsctool -d exited cleanly
[PASS] SHA-256 identical after round trip (0 mismatches)
[PASS] UF_COMPRESSED cleared (0 still set)
```

The six skipped files were skipped **correctly**: a pre-existing resource fork, a zero-byte
file, three incompressible random-data files (`.bin`, `.jpg`, `.mp4`), and an `.icns`.
afsctool's own refusal heuristics are sound; our safety rules are belt-and-braces over them,
not a substitute.

---

## 2. Sparse files materialize — **new hard exclusion**

[SAFETY.md](SAFETY.md) listed this as `[unverified]`. It is now verified, and worse than expected.

```
BEFORE:  logical 10,485,760   st_blocks 0    ->        0 bytes on disk
AFTER:   logical 10,485,760   st_blocks 64   ->   32,768 bytes on disk
```

A 10 MB sparse file occupying **nothing** was compressed into one occupying **32 KB**.
Compression *materializes* the sparse extents. Two consequences:

1. It is a net loss, always. There is no sparse file for which this is a good trade.
2. **Our savings arithmetic inverts.** Comparing physical against *logical* size reports
   "99.7% saved" for an operation that consumed 32 KB more disk than it started with.

Scale this to a sparse disk image — a 100 GB bundle with 2 GB in use — and a "helpful"
compression pass could try to write out the whole zero-filled extent. Sparse files move
from `[unverified]` to a **hard exclusion, not user-overridable**, and the estimator must
never report savings for a file whose physical size is below its allocated block count.

---

## 3. Hard links were being counted three times — **bug, now fixed**

Three paths, one inode, `nlink = 3`, `st_blocks = 8`:

```
naive sum   = 12,288 bytes
actual disk =  4,096 bytes
```

Every path was contributing its full physical size to the aggregate. On the real corpus this
is not a rounding error:

| Walk | Without dedup | With dedup | Phantom |
|---|---|---|---|
| `/System/Library` compressed files | 131,286 | 112,788 | **18,498** |
| `/System/Library` logical | 39.76 GB | 38.77 GB | **~1.0 GB** |
| `/Applications` compressed files | 141,868 | 133,406 | **8,462** |
| `/Applications` logical | 179.73 GB | 178.90 GB | **~0.83 GB** |

Phantom files and imaginary gigabytes on ordinary system directories, not contrived fixtures. Totals
are now counted once per `(st_dev, st_ino)`; `WalkResult.hardLinkDuplicates` reports how many
extra paths were seen so the UI can explain the discrepancy rather than hide it.

---

## 4. Physical size for inline storage is `max`, not `sum` — **bug, now fixed**

[ADR-0002](DECISIONS.md#adr-0002-native-detection-subprocess-only-for-mutation) correctly
predicted that `st_blocks * 512` alone is wrong. My first correction was also wrong.

Inline-xattr files fall into two cases, and adding the xattr length to `st_blocks`
double-counts the second:

| File | `st_blocks` | xattr | Truth | Old rule (sum) | New rule (max) |
|---|---|---|---|---|---|
| `tiny-100b.txt` | 0 | 48 | 48 | 48 ✓ | 48 ✓ |
| `née café.txt` | 4096 | 202 | 4096 | 4298 ✗ | 4096 ✓ |

A small xattr lives in the inode record (`st_blocks = 0`); a larger one spills to its own
allocated block, which `st_blocks` then already accounts for.

After the fix, cross-checking every file against `afsctool -v`: **agree=7, disagree=0.** The
only remaining divergence is the two files where afsctool reports `0 bytes` and we report the
honest 48 and 62 — **afsctool under-reports inline storage as free**, so Pomace is more
accurate than the tool it wraps, exactly as ADR-0002 hoped.

---

## 5. Walk performance — target met, FTS wins

`/System/Library`, 289,956 files / 161,573 directories, best of 3:

| Implementation | Time | Files/sec |
|---|---|---|
| FTS + full inspection | **8.64s** | 33,561 |
| FTS, no inspection | 5.34s | 54,297 |
| `FileManager.enumerator` | 11.45s | 25,329 |

`/Applications`, 1,238,039 files / 207,413 directories, best of 2:

| Implementation | Time | Files/sec |
|---|---|---|
| FTS + full inspection | **20.26s** | 61,100 |
| FTS, no inspection | 14.40s | 85,957 |
| `FileManager.enumerator` | 32.38s | 38,229 |

FTS is 1.33–1.60× faster than FileManager while doing strictly more work, because `fts_read`
returns a populated `stat` and saves an `lstat` per file. **The M0 target was 500k files
under 30s; we walked 1.24M in 20.26s** — 2.5× the target size in two-thirds the time.

**Scan cost tracks compressed files, not total files.** Throughput was 61,100 files/sec on
`/Applications` (10.8% compressed) but only 33,561 on `/System/Library` (39% compressed),
because the decmpfs xattr read only happens for files already carrying `UF_COMPRESSED`. A
directory Pomace has already compressed therefore rescans more slowly than a fresh one —
which is precisely the watched-directory case, so budget for it.

**Incidental finding:** `/System/Library` is already **39% compressed** (112,788 of 289,956
files), 38.77 GB logical against 32.92 GB physical. Apple ships the OS using the very
mechanism Pomace exposes, which is both a useful correctness check on our detector at scale
and a good line for the onboarding copy.

---

## 6. Decompression speed — LZFSE confirmed

Never previously measured; [ADR-0011](DECISIONS.md#adr-0011-lzfse-default-not-zlib-9) asserted
it. Cold-ish cache via `hdiutil detach`/`attach` between runs, same 48.8 MB read each time:

| Stored as | Read throughput | vs uncompressed |
|---|---|---|
| Uncompressed | 1806.8 MB/s | — |
| **LZFSE** | **1626.1 MB/s** | −10% |
| LZVN | 1524.5 MB/s | −16% |
| ZLIB | 1219.6 MB/s | −32% |

**LZFSE reads 33% faster than ZLIB** and costs only 10% against uncompressed. Since reads
recur forever and compression happens once, this widens the ADR-0011 case considerably.

*Caveat:* 48 MB completing in 27–40 ms is a small, noisy measurement, and `detach`/`attach`
is not as thorough as `purge`. The ranking is monotonic and matches theory, but treat the
absolute figures as indicative.

---

## 7. Negative savings are real and must be handled

`has-rsrc.txt`: 36,000 logical, 40,960 physical — **−13.8% "savings"** from a pre-existing
resource fork. The UI must render negative savings without breaking layout or claiming a
gain, and the estimator must never sort such files to the top of a "biggest wins" list.

---

## 8. Process note: the first test run was vacuous

The initial integrity run printed `ALL CHECKS PASSED` while the walker returned **zero
files** — `FTS_NOSTAT_TYPE` suppresses the `stat`, so regular files arrive as `FTS_NSOK` and
nothing matched `FTS_F`. Every check passed by iterating an empty set.

A test suite that cannot fail is worse than no test suite. `verify` should assert a minimum
file count before it is willing to report success, and CI must fail on a zero-file baseline.

---

## 9. TCC inheritance — **ADR-0006 holds**

The highest-risk assumption in the design: does a launchd-spawned instance of the same
signed binary carry the GUI app's TCC identity? Tested with a Developer ID-signed probe
(`TeamIdentifier=REDACTED`) installed to `/Applications` and registered via
`SMAppService.agent(plistName:)`. Registration returned `.enabled` immediately — no
`.requiresApproval` step.

```
AGENT (launchd)   pid=9007 ppid=1 | Desktop=OK(14) Documents=OK(187) Downloads=OK(11)
                                  | FDA:Mail=DENIED FDA:Safari=DENIED
GUI (foreground)  pid=9043 ppid=1 | Desktop=OK(14) Documents=OK(187) Downloads=OK(11)
                                  | FDA:Mail=DENIED FDA:Safari=DENIED
shell (different identity)        | Mail=OK Safari=OK
```

**Byte-for-byte identical between the two modes**, and both are *more restricted* than the
shell that launched them. That third line is what makes this a real result rather than a
vacuous one: TCC is demonstrably enforcing and distinguishing code identities — the shell
holds Full Disk Access, the probe does not, and the probe's launchd-spawned agent is
neither more nor less privileged than its GUI self.

The single-binary design in [ADR-0006](DECISIONS.md#adr-0006-scheduled-sweeps-re-launch-the-main-binary-headless)
is sound. The `SMAppService.daemon` fallback is not needed.

**Two caveats.** We confirmed the agent and GUI *share* an identity; we did not directly
exercise **granting** Full Disk Access to the app and watching the agent inherit it — that
follows from shared identity but is one inferential step. And the Desktop/Documents/Downloads
access appeared without any prompt, which may be an artifact of the app first being launched
from a shell that already held FDA; a user double-clicking a fresh download could see a
prompt we never triggered. M1's onboarding must handle the prompt path even though this run
never hit it.

*Teardown verified:* unregistered (status 0), removed from `/Applications`, no launchd job,
no plist in `~/Library/LaunchAgents`, log directory and test image deleted.

## 10. Still open
- [ ] Cold-cache compression benchmarks — `hdiutil` reattach helps, `sudo purge` would be
      better. The thread-count knee is still a warm-cache result.
- [ ] External and rotational media — the `-j` vs `-J` split and clamp-to-2 remain assumption.
- [ ] Intel fallback — `hw.perflevel0` is Apple-silicon shaped; untested on homogeneous cores.
- [ ] `-R` reverse workers — still unmeasured.
- [ ] Estimation-by-sampling accuracy against real compression.
