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

Ten sets of three hard-linked files, `afsctool -c -T LZFSE -S -f`, five repeats each:

| `-J` | Sets destroyed |
|---|---|
| **1** | **50 / 50 — every single one** |
| 2 | 4 / 50 |
| 3 | 0 / 50 |
| 4, 6, 8, 10 | 0 / 50 |

**Single-threaded compression destroys 100% of hard-linked files.** Two threads corrupt
roughly 8% of them, nondeterministically.

Things that do **not** prevent it:

- **`-f`** (afsctool's own hard-link detection) — 4/50 destroyed with it, 4/50 without.
- **Passing a directory** instead of explicit paths — 5/50 destroyed. This is the ordinary
  way people invoke afsctool.

Within a single invocation given all three paths at a high thread count, afsctool reports
`1 of 3 processed files`, so the detection logic clearly exists. It just does not hold at
low concurrency.

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

Pomace already passes explicit file lists rather than directories, so it can enforce this:
the engine collapses paths by `(linkCount > 1, inode)` and submits exactly one per inode.
This is both safe and complete — hard links *are* the same file, so compressing one link
compresses all of them. Verified: the siblings come back `compressed` without ever being
named on the command line.

Validated at the worst-case `-J2`: **0 failures in 100 sets**, then 0 failures across 90 sets
in six end-to-end engine runs on fresh disk images.

A second, independent guard: `SystemProfile.minimumSafeThreads = 3`. No policy path may emit
a thread count below it, and a test asserts this across every mode and every combination of
runtime conditions. The inode rule is the actual fix; the floor exists so that one missed
path cannot land in the 100%-loss case.

## 5. Consequences beyond Pomace

Worth reporting upstream. In the meantime, anyone running afsctool by hand should know:

- `afsctool -c -J1 <anything containing hard links>` **will** destroy those files.
- `-J2` will corrupt some of them, unpredictably.
- `-f` does not protect you, and neither does passing a directory.
- Three or more threads showed no failures in 250 sampled sets — which is evidence of
  safety, not proof of it.

Hard links are common in the places people most want to compress: Time Machine local
snapshots, `node_modules` with pnpm or npm links, Homebrew Cellar, and any tree built with
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
