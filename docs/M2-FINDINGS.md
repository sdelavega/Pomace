# M2 Findings — a data-loss bug in afsctool

**Run:** 2026-08-26 · MacBook Air M5, macOS 27, APFS · afsctool 1.7.3

M2 found and fixed a bug that silently destroys file contents. It is an **upstream afsctool
defect**, not a Pomace one, and it affects anyone using afsctool directly.

---

## 1. What happens

**Compressing a set of hard-linked files can truncate them to zero bytes.** Content is
irrecoverably lost; the file remains, with its inode and link count intact, containing
nothing.

Discovered by accident: after a compress run through the app, three hard-linked fixtures
that had been 100,000 bytes reported as *"Empty file — nothing to compress"*. On disk:

```
size=0 blocks=8 nlink=3 ino=105 flags=-
sha256 = e3b0c44298fc1c14…   ← the hash of empty input
```

## 2. Reproduction

Ten sets of three hard-linked files each. Counts are files destroyed, on an internal APFS
volume (a sparse disk image behaves identically).

### Mode A — a directory walk without `-f`. Deterministic, 100%.

| Command | Destroyed |
|---|---|
| `afsctool -c <dir>` | **30 / 30** |
| `afsctool -c -S <dir>` | **30 / 30** |
| `afsctool -c -J1 <dir>` | **30 / 30** |
| `afsctool -c -f <dir>` | 0 / 30 |
| `afsctool -c -S -f <dir>` | 0 / 30 |

**The plainest invocation there is — `afsctool -c <dir>` — destroys every hard-linked file
under it.** `-f` prevents this mode entirely.

### Mode B — an explicit file list at one thread. Deterministic, 100%, and `-f` does not help.

| Command | Destroyed |
|---|---|
| `afsctool -c -J1 -f <files…>` | **30 / 30** |
| `afsctool -c -j1 -f <files…>` | **10 / 10** |
| `afsctool -c -f <files…>` *(no `-J`)* | 0 / 30 |

Note that the default and `-J1` are **not** the same code path: omitting the flag is safe,
asking for exactly one thread is not.

### Mode C — an explicit file list at two threads. Intermittent, rate unstable.

Observed between 0 and 31 per 100 across samples of the *same* command, so treat the rate as
"sometimes" rather than any particular figure. `-J4` and above showed no failures in every
sample taken.

### Affects every compressor

At `-J1` with an explicit list: ZLIB 10/10, LZVN 10/10, LZFSE 10/10.

### Correction

An earlier draft of this document claimed "`-f` does not prevent it" and "passing a
directory fails too" as general statements. Both came from conflating the two modes in one
test run. `-f` fully prevents Mode A; it does not prevent Mode B. The matrices above replace
those claims.

## 3. Why it nearly shipped

Pomace's own tuning policy clamped threads to **2** for external media and halved the count
under battery or thermal pressure — landing squarely in the corrupting range, and on
external drives, where large hard-linked trees are most likely to live.

M0's integrity check passed only by luck: it used `-J4` and the corpus contained exactly one
hard-link set. At four threads the failure rate was zero in every sample.

The corrupting run went through the GUI while the equivalent spike run was clean, because
the app detected `/Volumes/…` as external media and dropped to `-j2` while the spike used
`-J10`. Two code paths, one safe and one not, from the same policy engine.

## 4. The fix

**Never hand afsctool two paths that share an inode.**

Pomace passes explicit file lists rather than directories, so it can enforce this: the engine
collapses paths by `(linkCount > 1, inode)` and submits exactly one per inode. This is both
safe and complete — hard links *are* the same file, so compressing one link compresses all of
them. The siblings come back `compressed` without ever appearing on a command line.

The rule is sufficient on its own, at the worst possible settings: **0 failures in 300 sets**
across `-J1`, `-j1`, and `-J2` — including the `-J1` configuration that otherwise destroys
100%. Then 0 across 90 sets in six end-to-end engine runs on fresh disk images, and through
the GUI path that originally caused the loss.

Two further guards, neither load-bearing:

- **`SystemProfile.minimumSafeThreads = 3`.** No policy path may emit fewer, asserted across
  every mode and every combination of runtime conditions.
- **`-f` is always passed**, which independently closes Mode A.

## 5. Consequences beyond Pomace

Drafted for upstream in [`upstream/afsctool-hardlink-issue.md`](../upstream/afsctool-hardlink-issue.md),
with a self-contained reproduction at [`upstream/repro-hardlink-loss.sh`](../upstream/repro-hardlink-loss.sh).
**Not yet filed** — awaiting review.

In Mode C afsctool also crashes (`SIGBUS` in `_platform_memcmp` under `compressFile`, on a
worker thread) in roughly 12 of 15 runs, which suggests the truncation and the crash share a
cause: verification comparing against a mapping another worker has just invalidated.

For anyone running afsctool by hand:

- **Always pass `-f`.** Without it, `afsctool -c <dir>` destroys every hard-linked file in
  the tree. This is the default invocation and the one most documentation shows.
- **Never pass `-J1` or `-j1`** with an explicit file list. `-f` will not save you.
- **`-J2` is unsafe intermittently.** Use four or more threads, or omit the flag.
- Omitting `-J` entirely is safe; asking for one thread is not.

Hard links are common in exactly the trees people most want to compress: Time Machine local
snapshots, `node_modules` under pnpm or npm links, Homebrew's Cellar, and anything built with
`cp -al`.

## 6. Method note

The bug was found because the scan *after* a compression run disagreed with the scan before
it — three files newly reported as empty. That discrepancy was visible only because Pomace
re-scans natively after every mutation and shows the result, rather than trusting afsctool's
own summary ([ADR-0002](DECISIONS.md#adr-0002-native-detection-subprocess-only-for-mutation),
[ARCHITECTURE §4.3](ARCHITECTURE.md)). afsctool reported `succeeded=121, failed=0` for the
run that destroyed three files.

The first instinct was to blame Pomace's explicit-path batching, which is the newest and
least proven part of the design. Testing that hypothesis directly is what showed the
directory case fails too — the batching was innocent, and the reflex to suspect it first
would have produced a fix that changed nothing.
