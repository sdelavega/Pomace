# Pomace

**Transparent filesystem compression for macOS, with a native UI and a memory.**

> *Pomace* — the dense solids left behind after apples are pressed.

Pomace is a native macOS app around [`applesauce`](https://github.com/Dr-Emann/applesauce), which
applies HFS+/APFS *transparent compression* to files on disk. Compressed files read back
byte-identically through the normal filesystem APIs — no mounting, no archive format, no
special handling by other apps. The space is simply reclaimed.

It is spiritually a Mac answer to Windows' [CompactGUI](https://github.com/IridiumIO/CompactGUI),
with one significant addition: **watched folders**. Pomace remembers the directories you
care about and re-sweeps them on a schedule, recompressing new files and files that were
decompressed by being written to.

## Status

**M3 complete; M4 polish in progress.** Pomace has scanning, verified mutation through
Applesauce, watched-directory sweeps, persisted history, and a native macOS UI. The current
unit suite has 56 passing tests; `pomace-spike` preserves the original filesystem probes.
See the [Roadmap](docs/ROADMAP.md) and [M0 Findings](docs/M0-FINDINGS.md).

## Why this exists

The command-line tools are capable and completely unapproachable. You get one shot at a
long-running command whose flags materially affect your data, little progress reporting, and
no way to know afterwards what state your disk is actually in. And
compression *drifts* — the moment a file is written to, macOS silently decompresses it, so
a directory you compressed six months ago is now partly uncompressed and you have no way
to know without rescanning it by hand.

Pomace covers three things the CLI doesn't:

1. **See before you act.** Scan a directory, see per-file and aggregate estimated savings,
   what's already compressed and with which algorithm, and what should be skipped — before
   anything is modified.
2. **Stay compressed.** Register a directory as watched; a background agent re-sweeps it on
   a schedule and recompresses drift.
3. **Just work.** If `applesauce` isn't installed, Pomace installs it.

## Requirements

- macOS 14 Sonoma or later ([ADR-0012](docs/DECISIONS.md#adr-0012-macos-14-deployment-floor)); developed against macOS 27
- Apple silicon or Intel
- APFS or HFS+ volume
- `applesauce` — installed by Pomace on first run if absent

## Documents

| Document | What's in it |
|---|---|
| [PRD](docs/PRD.md) | What Pomace does, for whom, and what it deliberately doesn't do |
| [Architecture](docs/ARCHITECTURE.md) | Process model, module layout, scan engine, scheduling |
| [Decisions](docs/DECISIONS.md) | ADR log — the load-bearing technical choices and their costs |
| [Defaults](docs/DEFAULTS.md) | Auto-tuning policy, benchmark data, and how options are disclosed |
| [Safety](docs/SAFETY.md) | What must never be compressed, and why. **Read before writing mutation code.** |
| [M0 Findings](docs/M0-FINDINGS.md) | Spike results — what held, what broke, what's still open |
| [M2 Findings](docs/M2-FINDINGS.md) | **A data-loss bug in afsctool** — the reason Pomace moved to applesauce ([ADR-0015](docs/DECISIONS.md#adr-0015-applesauce-replaces-afsctool)) |
| [Roadmap](docs/ROADMAP.md) | Phased milestones from spike to release |

## Licensing note

`applesauce` is **GPL-3.0**. Pomace does **not** bundle, link against, or redistribute it —
it invokes a copy installed on the user's own system, and installs one on request if missing.
See [ADR-0003](docs/DECISIONS.md#adr-0003-never-bundle-afsctool) and
[ADR-0015](docs/DECISIONS.md#adr-0015-applesauce-replaces-afsctool).

Pomace's own license is not yet chosen. See [ADR-0008](docs/DECISIONS.md#adr-0008-project-license-open).
