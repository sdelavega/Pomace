# Pomace

**Transparent filesystem compression for macOS, with a native UI and a memory.**

> *Pomace* — the dense solids left behind after apples are pressed.

Pomace is a native macOS app around [`afsctool`](https://github.com/RJVB/afsctool), which
applies HFS+/APFS *transparent compression* to files on disk. Compressed files read back
byte-identically through the normal filesystem APIs — no mounting, no archive format, no
special handling by other apps. The space is simply reclaimed.

It is spiritually a Mac answer to Windows' [CompactGUI](https://github.com/IridiumIO/CompactGUI),
with one significant addition: **watched folders**. Pomace remembers the directories you
care about and re-sweeps them on a schedule, recompressing new files and files that were
decompressed by being written to.

## Status

**M0 spike complete**, bar the TCC-inheritance test. `PomaceCore` has a working scan
engine with 18 passing tests; `pomace-spike` is the verification harness. No UI yet.
See [M0 Findings](docs/M0-FINDINGS.md).

## Why this exists

`afsctool` is excellent and completely unapproachable. You get one shot at a long-running,
uninterruptible command whose flags materially affect your data, no meaningful progress
reporting, and no way to know afterwards what state your disk is actually in. And
compression *drifts* — the moment a file is written to, macOS silently decompresses it, so
a directory you compressed six months ago is now partly uncompressed and you have no way
to know without rescanning it by hand.

Pomace covers three things the CLI doesn't:

1. **See before you act.** Scan a directory, see per-file and aggregate estimated savings,
   what's already compressed and with which algorithm, and what should be skipped — before
   anything is modified.
2. **Stay compressed.** Register a directory as watched; a background agent re-sweeps it on
   a schedule and recompresses drift.
3. **Just work.** If `afsctool` isn't installed, Pomace installs it.

## Requirements

- macOS 13 Ventura or later (`SMAppService`); developed against macOS 27
- Apple silicon or Intel
- APFS or HFS+ volume
- `afsctool` — installed by Pomace on first run if absent

## Documents

| Document | What's in it |
|---|---|
| [PRD](docs/PRD.md) | What Pomace does, for whom, and what it deliberately doesn't do |
| [Architecture](docs/ARCHITECTURE.md) | Process model, module layout, scan engine, scheduling |
| [Decisions](docs/DECISIONS.md) | ADR log — the load-bearing technical choices and their costs |
| [Defaults](docs/DEFAULTS.md) | Auto-tuning policy, benchmark data, and how options are disclosed |
| [Safety](docs/SAFETY.md) | What must never be compressed, and why. **Read before writing mutation code.** |
| [M0 Findings](docs/M0-FINDINGS.md) | Spike results — what held, what broke, what's still open |
| [Roadmap](docs/ROADMAP.md) | Phased milestones from spike to release |

## Licensing note

`afsctool` is **GPL-3.0-only AND BSL-1.0**. Pomace does **not** bundle, link against, or
redistribute it — it invokes a copy installed on the user's own system, and installs one on
request if missing. See [ADR-0003](docs/DECISIONS.md#adr-0003-never-bundle-afsctool).

Pomace's own license is not yet chosen. See [ADR-0008](docs/DECISIONS.md#adr-0008-project-license-open).
