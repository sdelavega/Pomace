# Pomace — Defaults and Auto-Tuning

> **Superseded in part by [ADR-0015](DECISIONS.md#adr-0015-applesauce-replaces-afsctool).**
> Pomace now drives `applesauce`, which parallelises internally and exposes no thread flag,
> so §1.2, §1.3 and every thread-related row in §2 are historical — kept because they record
> real measurements and because the reasoning still explains why the afsctool era looked the
> way it did. The compressor comparison in §1.1 and the disclosure model in §3–§4 still stand.

**Status:** Draft · **Last updated:** 2026-08-26

The product promise is that Pomace picks correctly without being asked. This document is
the policy behind that promise: what gets decided automatically, from which inputs, and the
measurements the decisions rest on.

Companion ADRs: [ADR-0009](DECISIONS.md#adr-0009-progressive-disclosure--automatic-by-default-every-flag-reachable)
(disclosure tiers), [ADR-0010](DECISIONS.md#adr-0010-choose-the-compressor-by-measuring-the-directory-not-by-static-default)
(measure, don't guess), [ADR-0011](DECISIONS.md#adr-0011-lzfse-default-not-zlib-9).

---

## 1. Measurements

All figures below: MacBook Air, Apple M5 (4 performance + 6 efficiency cores), 24 GB, macOS 27,
internal APFS. Corpus 1.3 GB / 6,390 files — mach-o binaries plus a Python site-packages tree
(mixed text and native extensions). afsctool 1.7.3.

**Read these as directional, not authoritative.** Single machine, single corpus, one run per
configuration, no error bars, and a warm page cache — so I/O never became the bottleneck and
the thread numbers are a CPU-bound upper bound. Cold-cache and external-volume behavior will
differ, probably substantially. M0 re-runs this properly; see [§6](#6-what-m0-must-re-measure).

### 1.1 Compressor

| Compressor | Saved | Time | Throughput |
|---|---|---|---|
| ZLIB-1 | 63.7% | 5.0s | 277.7 MB/s |
| ZLIB-5 *(afsctool default)* | 66.1% | 7.5s | 185.3 MB/s |
| ZLIB-9 | **66.2%** | 25.0s | 55.6 MB/s |
| LZVN | 63.2% | — | 284.2 MB/s |
| **LZFSE** | 65.6% | **3.9s** | **354.4 MB/s** |

The level knob is nearly inert. **ZLIB-9 buys 0.1 percentage points over ZLIB-5 and costs
3.3× the time.** Against LZFSE it buys 0.6 points for 6.4× the time — on this corpus, 21
extra seconds to reclaim about 8 MB. Extrapolated to a 500 GB library that is hours of extra
CPU for a few GB.

And compression is paid once while decompression is paid on every subsequent read, where
LZFSE — Apple's own format, tuned for exactly this — is materially faster than ZLIB. The
ratio comparison understates the case for LZFSE.

### 1.2 Thread scaling (LZFSE)

| `-J` | Throughput | Speedup | Marginal gain per added thread |
|---|---|---|---|
| 1 | 117.9 MB/s | 1.00× | — |
| 2 | 221.6 MB/s | 1.88× | +103.7 MB/s |
| **4** | **354.4 MB/s** | **3.01×** | +66.4 MB/s |
| 6 | 395.4 MB/s | 3.35× | +20.5 MB/s |
| 8 | 422.6 MB/s | 3.58× | +13.6 MB/s |
| 10 | 431.1 MB/s | 3.66× | +4.3 MB/s |

**The knee sits exactly at the performance-core count.** Scaling is near-linear to 4, then
collapses — each P-core adds 66–104 MB/s, each E-core adds 4–20 MB/s. Four threads capture
82% of maximum throughput using 40% of the cores.

That ratio is the whole argument for the default. For a background sweep, leaving six cores
free for the user's actual work is worth 18% of a throughput number nobody is watching.

### 1.3 `-j` versus `-J`

`-J4` (fully concurrent) 354.4 MB/s against `-j4` (exclusive disk I/O) 281.3 MB/s — `-J` is
26% faster on internal NVMe. Untested on external or rotational media, where the exclusive-I/O
form is expected to win; that assumption is unverified and flagged in [§6](#6-what-m0-must-re-measure).

---

## 2. Policy

Every row is computed, never asked. Each carries a justification string surfaced in
Settings → Advanced, because a user who can see *why* Pomace chose something is a user who
will trust it.

| Flag | Automatic rule | Rationale |
|---|---|---|
| `-T` compressor | Sample the directory, measure, pick the winner. LZFSE when inconclusive. | [ADR-0010](DECISIONS.md#adr-0010-choose-the-compressor-by-measuring-the-directory-not-by-static-default) |
| `-<level>` | 9 **only** if ZLIB was chosen; irrelevant otherwise | ZLIB-only flag; near-inert (§1.1) |
| `-J` / `-j` threads | `hw.perflevel0.physicalcpu` for background sweeps; all physical cores for foreground runs the user is watching | Knee at P-core count (§1.2) |
| | Halve on battery, in Low Power Mode, or `thermalState > .fair`, floored at 3 | Citizenship, bounded by the hard-link safety floor |
| | Clamp to 3 on external or rotational media | I/O bound; **never below 3** — afsctool corrupts hard links at 1–2 threads ([M2-FINDINGS](M2-FINDINGS.md)) |
| | `-J` on internal SSD, `-j` on external | 26% faster on NVMe (§1.3) |
| `-S` sort | **Always on** | Safety, not tuning — see below |
| `-R` reverse workers | Half of thread count when file count is large | Load balance on skewed size distributions — **unmeasured**, see §6 |
| `-s` min savings | 5% | Don't rewrite a file to reclaim nothing |
| `-f` hard links | **Always on**, never exposed as off | Correctness |
| `-m` max file size | Unlimited; warn above 4 GB | Long and uninterruptible mid-file |
| `-b` backup | Off; offered on a directory's first run | Needs free space equal to the uncompressed set |
| `-t` / `-i` type filter | **Unused.** Native extension skip-list instead. | Our scanner already knows the types; see §4 |
| `-n` no-verify | **Never. Not exposed at any tier.** | [SAFETY.md §4](SAFETY.md#4-operational-rules) |
| `-L` larger chunks | **Never.** | afsctool's own help calls it "not recommended" |
| `-v` verbosity | `-v` always, for parseable per-file output | Feeds the progress UI, never shown raw |

### Why `-S` is not a preference

Sorting small-files-first means the largest files are processed last. If the volume runs
short of working space, the failure lands on the final file having already banked every
small win — instead of a large file consuming the headroom early and starving the rest.
That is a data-safety property, so it is always on and does not appear in Settings.

---

## 3. Disclosure tiers

**Tier 1 — the default.** Add a folder. See "You'll save about 12.4 GB." Press Compress.
No algorithm, no threads, no level, no slider.

**Tier 2 — intent, in the directory inspector.** One segmented control:

- **Automatic** *(default)* — measure and decide
- **Maximum savings** — accept slower compression for the best ratio
- **Fastest** — quickest acceptable pass

These select a coordinated *preset* (compressor + level + threshold together), never an
individual flag. The wording must stay outcome-shaped; the moment it says "LZFSE" it has
become Tier 3.

**Tier 3 — Settings → Advanced, per-directory.** Every flag, on the Xcode build-settings
model. Each row shows the computed value **and why**, with an override that visibly marks
the row as overridden and offers one-click revert:

```
Threads          4    ▾   Automatic — matched to 4 performance cores
Compressor    LZFSE   ▾   Automatic — measured fastest at 65.6% on this folder
Level             —       Not applicable to LZFSE
Sort order    Small first  Always on — protects against low disk space
```

The pane's primary job is **diagnostic**. Being able to see what Pomace decided, and why, is
what makes the automatic behavior trustworthy rather than opaque; the ability to override is
almost a side effect.

Overrides are per-directory. The right settings for a video library and a source tree differ.

---

## 4. On the slider

A slider is entirely within Apple's vocabulary — that instinct isn't wrong. But a *ZLIB
level* slider specifically fails on three counts:

1. **It barely does anything.** 1 → 9 moves the ratio 63.7% → 66.2%, and the top half of
   that range (5 → 9) is worth 0.1 points for 3.3× the time. A control whose full travel
   changes almost nothing teaches users their input doesn't matter.
2. **It's dead for two of three compressors.** LZFSE and LZVN have no level. The slider
   would be greyed out under the recommended default, which is a bad look for a control
   prominent enough to be a slider.
3. **It's mechanism, not outcome.** "Level 7" isn't a thing users want; "smaller" and
   "faster" are.

If a continuous control is wanted, the honest one is a **two-stop Faster ←→ Smaller** that
maps to the entire preset — compressor, level, and threshold at once — and is disabled in
Automatic mode. That preserves the feel while staying outcome-framed. My recommendation is
the three-way segmented control in Tier 2 instead, because there are genuinely only about
three distinct useful answers here, and a slider implies a continuum the underlying
mechanism does not provide.

---

## 5. Note on the reference flag set

The design was calibrated against `afsctool -clfvvvi -J4 -S -9`. Three observations from
reproducing it:

- **`-J4` matches the computed optimum exactly.** `hw.perflevel0.physicalcpu` returns 4 on
  this M5. The rule generalizes a hand-tuned choice rather than contradicting it.
- **`-i` without `-t` is a no-op.** **[verified]** `-i` inverts a content-type filter, and
  with no `-t` there is no filter to invert. Byte-identical results with and against it.
- **`-9` is active but close to pointless.** afsctool's default compressor is ZLIB
  **[verified]** — decmpfs type 4 — so `-9` does apply. It is also worth 0.1 points over the
  default level, at 3.3× the cost.

---

## 6. What M0 must re-measure

The numbers in §1 are good enough to choose defaults from and not good enough to ship
claims about.

- [ ] **Cold cache.** Every run above was warm. Re-run with the cache purged between runs —
      this is the single biggest threat to the thread-count conclusion, since real sweeps are
      I/O bound and the knee may move well below 4.
- [ ] **Repeat runs with error bars.** One run per configuration is not a measurement.
- [ ] **External and rotational media.** The `-j` vs `-J` split and the clamp-to-2 rule are
      both currently assumption, not data.
- [ ] **Diverse corpora.** Binaries and Python source are one shape of data. Add source
      trees, documents, mixed media, and a deliberately incompressible set.
- [ ] **`-R` reverse workers.** Entirely unmeasured. Determine whether it helps enough to
      justify being in the policy table at all.
- [ ] **Decompression speed.** Never measured here, and it is the cost users pay repeatedly.
      LZFSE is expected to win comfortably; confirm it.
- [ ] **Intel Macs.** `hw.perflevel0` is Apple-silicon shaped. Determine the fallback rule
      for homogeneous-core machines (likely `hw.physicalcpu`, possibly halved).
- [ ] **Sampling accuracy.** Does measuring N files predict the whole directory within ±15%?
