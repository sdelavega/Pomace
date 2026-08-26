# Data loss: compressing hard-linked files truncates them to zero bytes

**afsctool 1.7.3** (Homebrew; the binary's banner self-reports `1.7.2`)
**macOS 27.0, Apple M5, APFS** — reproduced on both an internal volume and a sparse disk image

---

## Summary

Compressing a set of hard-linked files can truncate them to **zero bytes**, losing their
contents irrecoverably. The inode and link count survive; the data does not.

There appear to be two distinct failure modes, one of which is reachable through the
**default invocation**, `afsctool -c <dir>`.

In the threaded case afsctool also crashes with `SIGBUS` inside its own post-compression
verification, which suggests the two symptoms share a cause.

A self-contained reproduction script is attached at the end.

## Reproduction

Ten sets of three hard-linked files, 100,000 bytes each:

```bash
yes "hard linked content" | head -5000 > s1-a.txt
ln s1-a.txt s1-b.txt
ln s1-a.txt s1-c.txt
```

Counts below are files truncated to zero, out of ten sets.

### Mode A — directory walk without `-f`: deterministic, 100%

| Command | Destroyed |
|---|---|
| `afsctool -c <dir>` | **10 / 10** |
| `afsctool -c -S <dir>` | **10 / 10** |
| `afsctool -c -J1 <dir>` | **10 / 10** |
| `afsctool -c -f <dir>` | 0 / 10 |
| `afsctool -c -S -f <dir>` | 0 / 10 |

`-f` prevents this mode completely. But the invocation that loses data is the simplest one
in the help text, and `-f` is documented as "detect hard links" — which reads like a
reporting nicety rather than something required to avoid destroying files.

### Mode B — explicit file list at exactly one thread: deterministic, 100%, `-f` does not help

| Command | Destroyed |
|---|---|
| `afsctool -c -J1 -f <files…>` | **10 / 10** |
| `afsctool -c -j1 -f <files…>` | **10 / 10** |
| `afsctool -c -f <files…>` *(no `-J`)* | 0 / 10 |

Omitting the thread flag is safe; requesting one thread is not. The default and `-J1`
evidently take different code paths.

### Mode C — explicit file list at two threads: intermittent

`afsctool -c -J2 -S -f <files…>` destroys files unpredictably. Across repeated samples of the
identical command the rate ranged from **0 to 31 per 100 sets**, so it is genuinely
nondeterministic rather than a fixed proportion. `-J4` and above showed no failures in any
sample taken (roughly 250 sets).

### All three compressors

At `-J1` with an explicit list: ZLIB 10/10, LZVN 10/10, LZFSE 10/10 destroyed.

## The crash

In Mode C, afsctool frequently crashes — **12 of 15 runs** in one sample:

```
Exception: EXC_BAD_ACCESS (SIGBUS), KERN_MEMORY_ERROR at 0x0000000100b14000

Thread 3 crashed:
  libsystem_platform.dylib   _platform_memcmp
  afsctool                   compressFile
  afsctool                   FileEntry::compress(FileProcessor*, ParallelFileProcessor*)
  afsctool                   FileProcessor::Run(void*)
  afsctool                   Thread::EntryPoint(void*)
```

`KERN_MEMORY_ERROR` on a `memcmp` inside `compressFile` looks like a mapping that became
invalid underneath the reader — consistent with the post-compression verification comparing
against a mapped region of a file that another worker has just rewritten.

## Suggested mechanism

Speculative, offered only because it fits every observation: worker threads pick up two
different *paths* that resolve to the same *inode*. One thread rewrites the file — moving the
data into the resource fork and truncating the data fork — while the other is mid-verification
against a mapping of the old data fork. That mapping is now past EOF, giving `SIGBUS`, and
the file is left truncated.

That would explain why the rate is nondeterministic, why it disappears at higher thread
counts (different work distribution), and why `-f` fixes the directory walk but not an
explicit list — presumably the de-duplication happens during directory enumeration rather
than at the point of compression.

## Workaround

Passing **one path per inode** is safe at every setting tested, including the `-J1`
configuration that otherwise destroys 100%: **0 failures in 300 sets** across `-J1`, `-j1`,
and `-J2`.

It is also complete, since hard links are the same file — the paths never named on the
command line come back compressed anyway:

```bash
$ afsctool -c -T LZFSE -J1 -S -f s*-a.txt     # only the "a" link of each set
$ stat -f %Sf s1-b.txt
compressed
```

## Why this matters

Hard links are common in the trees people most want to compress: Time Machine local
snapshots, `node_modules` under pnpm or npm links, Homebrew's Cellar, and anything built with
`cp -al`.

The loss is also silent. In the run that destroyed three files, afsctool reported success and
a plausible savings figure; nothing in its output indicated a problem. It was found only by
hashing the files independently afterwards.

## Reproduction script

`repro-hardlink-loss.sh` — creates its corpus in `mktemp -d`, touches nothing else, and
removes it on exit.

```bash
./repro-hardlink-loss.sh [path-to-afsctool]
```

Sample output:

```
MODE A — directory walk without -f
  afsctool -c <dir>                  10 / 10 destroyed
  afsctool -c -S <dir>               10 / 10 destroyed
  afsctool -c -f <dir>                0 / 10 destroyed

MODE B — explicit file list at one thread
  afsctool -c -f <files>              0 / 10 destroyed
  afsctool -c -J1 -f <files>         10 / 10 destroyed
  afsctool -c -j1 -f <files>         10 / 10 destroyed

MODE C — explicit file list at two threads
  afsctool -c -J2 -S -f <files>       1 / 10 destroyed
  afsctool -c -J4 -S -f <files>       0 / 10 destroyed

WORKAROUND — one path per inode, at the worst setting
  one path per inode, -J1             0 / 10 destroyed   (siblings: compressed)
```

---

Happy to test a patch, run a larger sample, or gather more crash reports if that would help.
Thanks for maintaining afsctool — it does something genuinely useful that nothing else does.
