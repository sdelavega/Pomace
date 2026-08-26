# Pomace — Safety Rules

**Status:** Draft · **Last updated:** 2026-08-26

**Read this before writing any code that mutates files.** Pomace's entire value depends on
users trusting it with directories they care about. One data-loss report ends the project.

Confidence is marked on each claim: **[verified]** confirmed on this platform, **[expected]**
well-established but unverified here, **[unverified]** plausible, must be tested in M0.

---

## 1. How transparent compression actually behaves

**[expected]** A decmpfs-compressed file reads back byte-identically through normal
filesystem APIs. The compression is invisible to every application. This is what makes it
safe in a way that archive formats are not.

**[expected]** **Writing to a compressed file decompresses it.** The kernel transparently
expands the file on modification. There is no in-place recompression. This is not a bug —
it is the mechanism behind the "drift" Pomace exists to counter — but it means compression
only pays off for write-once/read-many data. Frequently-written files will be decompressed
almost immediately, having cost CPU for nothing.

**[expected]** **Copying may or may not preserve compression, but never loses data.**
`ditto` and Finder preserve compression state; plain `cp` and `rsync` without `-X` produce
uncompressed copies of identical content. Nothing is lost either way — only the space
saving. Users should be told this so they aren't alarmed when a copied folder is larger.

**[expected]** Compression is a per-file property. There is no volume-level flag, and no
volume-level way to undo Pomace's work in bulk other than decompressing the files.

---

## 2. Never compress

Enforced in `PomaceCore/Safety`, evaluated during scan, surfaced in the UI with reasons.
These are hard exclusions — **not** user-overridable in v1.

| Target | Reason | Confidence |
|---|---|---|
| `/System`, `/usr` (except `/usr/local`), `/bin`, `/sbin` | Sealed System Volume is read-only; the attempt fails and wastes time | [verified] |
| `/Volumes/*` that are not APFS or HFS+ | Compression is Apple-filesystem-only; will fail or misbehave | [expected] |
| Network volumes (SMB, NFS, AFP) | decmpfs is a local-filesystem feature | [expected] |
| Live databases — `.sqlite` with an active `-wal`/`-shm`, `.realm`, running Postgres/MySQL data dirs | Constant writes; compression is instantly undone, and mutating files under an open writer risks corruption | [expected] |
| Photos, Mail, Music libraries while their app is running | Same — active writers with their own consistency assumptions | [expected] |
| VM disk images and bundles — `.vmdk`, `.qcow2`, `.utm`, Parallels/VMware bundles | Random-access written; some VM software uses low-level I/O paths | [expected] |
| Sparse files and sparse bundles | **Compression materializes them.** Measured: 10 MB sparse file went from 0 bytes on disk to 32,768. Always a net loss, and our savings math inverts. | **[verified 2026-08-26]** |
| Cloud-sync directories — iCloud Drive, Dropbox, Google Drive, OneDrive | Modifying every file can trigger a full re-upload of the directory; may also conflict with dataless/evicted placeholder files | [expected] |
| Time Machine backup volumes and local snapshots | Backup integrity; the volume format is not ours to touch | [expected] |
| **Two paths sharing one inode, in a single afsctool run** | **Destroys file contents.** afsctool truncates hard-linked files to zero bytes — 100% at `-J1` even with `-f`, intermittently at `-J2`. (A directory walk without `-f` is a separate 100%-loss mode.) Pomace submits one path per inode, which is sufficient at any thread count. | **[verified 2026-08-26]** — see [M2-FINDINGS](M2-FINDINGS.md) |
| Files with an existing non-decmpfs resource fork | afsctool's compression path uses the resource fork; a pre-existing one is a conflict | [expected] |
| Anything currently open for writing by another process | Race between afsctool and the writer | [expected] |

---

## 3. Warn, then allow

Presented with a clear explanation and an explicit opt-in.

- **Application bundles (`.app`).** This is afsctool's classic use case and is generally
  fine — code signature validation reads file *contents*, which are unchanged. **[expected]**
  But signature edge cases exist, so the warning stands, and Pomace should offer to
  re-verify with `codesign --verify --deep` after compressing a bundle.
- **Git working trees.** Safe, but `git status` may be slow on the next run as it re-stats
  everything, and any subsequent checkout decompresses touched files.
- **Hard-linked files.** afsctool's `-f` detects them; compressing one link affects every
  path pointing at that inode. Default `-f` on, and report link counts in the UI.
- **Very large individual files (>4 GB).** Long, memory-hungry, uninterruptible mid-file.
  Warn about the time cost.
- **Directories over ~100 GB.** Sweeps will be long. Recommend scheduling rather than
  running interactively.
- **Already-compressed content** — `.zip`, `.jpg`, `.mp4`, `.png`, `.heic`, `.gz`. Won't
  meaningfully shrink. Rather than warn, Pomace should default to skipping these by
  extension and let the min-savings threshold catch the rest.

---

## 4. Operational rules

These are requirements on Pomace's own implementation:

1. **Never pass `-n`.** afsctool's post-compression verification stays on, always. A
   nonexistent "fast mode" is not worth the risk surface.
2. **`-d` is a confirmed destructive action.** It removes the entire resource fork. The
   confirmation must name the file count and the path. Never reachable by a single click.
3. **Dry run before mutation, always.** Every compress is preceded by a scan. Nothing is
   modified until the user has seen the projected outcome.
4. **Cancel at file boundaries only.** Never signal afsctool mid-file. Track the current
   file so an interrupted run can be reported precisely.
5. **Re-verify after mutation.** Re-scan the affected subtree natively and persist that,
   not afsctool's summary. Same code path as the "before" figures.
6. **Free-space precondition.** Refuse to start when free space is under a safety margin —
   compression is not atomic and needs working room. Enforce a hard floor regardless of the
   user's wishes.
7. **Offer `-b` on first-time runs**, with an honest statement of the space it needs.
8. **Never sweep on battery, in Low Power Mode, under thermal pressure, or during a Time
   Machine backup.** Defer and record the reason.
9. **Log every mutation** with timestamp, path, flags passed, exit status, and duration.
   When something does go wrong, this log is the only thing that will explain it.
10. **Never mutate a path that failed a safety check**, even if a stale cached scan says
    it's fine. Re-evaluate at mutation time, not just scan time.
11. **Count bytes once per inode.** Hard links make one inode reachable by many paths;
    summing per-path triples a 4 KB file into 12 KB of imaginary savings. Measured at
    18,498 phantom files on `/System/Library` alone. See [M0-FINDINGS §3](M0-FINDINGS.md).
12. **Never report savings for a file whose physical size is below its allocated blocks.**
    That is the sparse-file signature, and the arithmetic is inverted there.
13. **A test run that inspects zero files must fail, not pass.** The first integrity run
    reported `ALL CHECKS PASSED` over an empty set. Assert a minimum baseline count.
14. **Never submit two paths that share an inode to one afsctool run**, and never emit a
    thread count below `SystemProfile.minimumSafeThreads`. Both guard the same data-loss
    bug ([M2-FINDINGS](M2-FINDINGS.md)); the inode rule is the fix and the floor is a
    backstop.
15. **Render negative savings honestly.** A pre-existing resource fork produces −13.8%;
    the UI must not display that as a gain or break its layout.

---

## 5. M0 verification checklist

Nothing ships until each of these is confirmed on a disposable APFS sparse image:

- [ ] Compress → SHA-256 matches pre-compression for every file in the corpus
- [ ] Decompress → SHA-256 still matches; file is byte-identical to the original
- [ ] Hard links survive compression with link counts intact
- [ ] Symlinks are never followed into unintended trees
- [ ] Zero-byte files, and files smaller than one block, are handled without error
- [ ] Sparse files behave correctly, or are provably excluded
- [ ] Files with pre-existing resource forks are correctly detected and skipped
- [ ] Killing afsctool mid-run leaves no truncated or corrupted file
- [ ] Full disk mid-compression fails safely, without data loss
- [ ] A signed `.app` still passes `codesign --verify --deep --strict` after compression
- [ ] Pomace's computed savings figures agree with `afsctool -v` across the corpus
- [x] **[done 2026-08-26]** decmpfs reads pass `XATTR_SHOWCOMPRESSION`; without it every
      compressed file misreads as uncompressed
- [x] **[done 2026-08-26]** inline-xattr storage (types 1/3/7/11) reports `st_blocks = 0`;
      physical size must come from the xattr length, not `st_blocks * 512`
