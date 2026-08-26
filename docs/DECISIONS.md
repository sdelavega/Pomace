# Pomace — Decision Log

Architecture Decision Records. Each entry states what was decided, why, and what it costs.
Superseding a decision means adding a new record, not editing an old one.

---

## ADR-0001: Swift and SwiftUI, single language

**Status:** Accepted · 2026-08-26

**Context.** "Native macOS look and feel" is a stated hard requirement, alongside launchd
scheduling and heavy filesystem traversal. Candidates: Swift/SwiftUI, Tauri (Rust + web),
Electron, Qt, a Rust core with a Swift UI, Python + PyObjC.

**Decision.** Swift 6 throughout — SwiftUI for the UI with AppKit interop where SwiftUI is
still thin (large outline views, split view behavior), a Swift package for the core, the
same binary for the headless agent.

**Why.** The native requirement eliminates Tauri, Electron, and Qt on its own; those can be
made to *approximate* Mac idiom and never quite land it, and we'd be fighting the framework
over sidebar behavior, table performance on 100k+ rows, and current system materials. The
other requirements confirm the choice: `SMAppService`, FSEvents, TCC interaction, and
`getxattr`/`lstat` are all Swift-first, and reaching them from Rust or JS means an FFI shim
that buys nothing. A Rust core would be defensible only if we were reimplementing
compression natively, and we aren't — afsctool remains the engine. Toolchain is already
present locally: Xcode 27, Swift 6.4.

**Costs.** macOS-only, permanently. No code sharing with any future non-Apple port. SwiftUI
on dense data-heavy views will need AppKit escape hatches; budget for that rather than
discovering it late.

---

## ADR-0002: Native detection, subprocess only for mutation

**Status:** Accepted · 2026-08-26

**Context.** afsctool can both report and mutate. The obvious design wraps the CLI for
everything.

**Decision.** Read compression state natively in Swift (`lstat` `st_flags & UF_COMPRESSED`,
plus the `com.apple.decmpfs` xattr). Invoke afsctool **only** to compress or decompress.

**Why.** Detection is two syscalls we're already making during the tree walk. Shelling out
instead means process spawn per tree, parsing human-formatted version-dependent output, no
incremental progress, and no cancellation. Native detection gives live progress, mid-scan
cancellation, structured results, and roughly two orders of magnitude more speed on large
trees. It also makes before/after comparisons trustworthy, since both come from the same
code path.

**Costs.** We reimplement a decmpfs reader and own its correctness, including undocumented
or future compression types. Computing *physical* size for compressed files is subtler than
`st_blocks * 512` and must be validated against afsctool's own figures before any number
reaches the UI — this is an explicit M0 gate.

---

## ADR-0003: Never bundle afsctool

**Status:** Accepted · 2026-08-26

**Context.** afsctool is licensed **GPL-3.0-only AND BSL-1.0**. Bundling the binary inside
`Pomace.app` would make distribution simple and offline-capable.

**Decision.** Pomace does not bundle, link against, embed, or redistribute afsctool. It
locates a copy already on the user's system, and if none exists, installs one *on the
user's behalf, with consent* — via `brew install afsctool` where Homebrew exists, otherwise
by fetching an official release into `~/Library/Application Support/Pomace/bin/`.

**Why.** Shipping a GPL-3.0 binary inside our distributable raises combined-work questions
we'd rather not have to answer, and would constrain Pomace's own license choice. Invoking a
separately-installed program over a CLI boundary is the conventional arm's-length
arrangement. And the stated product requirement — install afsctool if missing — *is* the
mitigation, so this costs nothing in user experience.

**Consequences.** First run requires network access if afsctool is absent. Pomace must
tolerate multiple afsctool versions with differing output formats. The install flow must
name the software, its source, and its license before proceeding, and must never install
silently.

---

## ADR-0004: Non-sandboxed, Developer ID distribution

**Status:** Accepted · 2026-08-26

**Context.** Mac App Store distribution requires the App Sandbox.

**Decision.** Non-sandboxed. Developer ID signed, hardened runtime, notarized, shipped as a
DMG. No Mac App Store.

**Why.** Three requested capabilities are each independently disqualifying: installing a
third-party executable, registering launchd agents that run arbitrary filesystem work, and
operating on user-chosen directories anywhere on disk with a background process that
outlives the UI session. Designing around a target we cannot reach would compromise the
product for nothing.

**Costs.** No App Store discovery or distribution. We own updates ourselves (Sparkle, or a
simple check-and-notify). Users see Gatekeeper's first-launch flow. **Note that
non-sandboxed is not unrestricted** — TCC still gates Desktop, Documents, Downloads, iCloud
Drive, and removable volumes, and those prompts must still be designed for.

---

## ADR-0005: launchd via SMAppService, not cron

**Status:** Accepted · 2026-08-26

**Context.** The request was for "cron jobs (or similar)" to re-sweep watched directories.

**Decision.** launchd agents, registered from inside the app bundle with
`SMAppService.agent(plistName:)`. Not cron, and not hand-written plists dropped into
`~/Library/LaunchAgents`.

**Why.** cron on macOS is vestigial: entries don't handle sleep windows well, there's no
per-user session integration, no I/O priority, no throttled scheduling class, and no way
for the app to query or manage its own job. launchd gives us `ProcessType: Background`,
`LowPriorityIO`, and `Nice` — all of which matter, because an unthrottled compression sweep
is very noticeable. `SMAppService` additionally keeps the agent inside the signed bundle,
so it's covered by notarization, it appears in Login Items where the user can see and
control it, and uninstalling the app removes it cleanly.

**Costs.** macOS 13+ floor. `SMAppService` registration can land in `.requiresApproval`,
so the UI must reflect real service status rather than assume success. Schedule changes
require unregister/rewrite/register.

---

## ADR-0006: Scheduled sweeps re-launch the main binary headless

**Status:** Accepted · 2026-08-26

**Context.** The scheduled sweep needs to run without the GUI. Conventional approach: a
separate helper executable inside the bundle.

**Decision.** The launchd agent invokes `Contents/MacOS/Pomace --sweep-all` — the *same*
executable as the GUI, which sets `NSApplication.activationPolicy = .prohibited` and runs
headless when that flag is present.

**Why.** TCC attributes disk-access grants to a code identity. One executable means one
identity, so the Full Disk Access the user grants Pomace is the grant the sweep runs under.
A separate helper binary risks needing its own grant and its own separate, baffling
permission prompt. One executable also means one thing to sign, notarize, and version — no
possibility of helper/app skew after an update.

**Costs.** Launch-time branching on arguments before any UI is constructed; get this wrong
and a Dock icon flashes during a background sweep. Slightly larger process image than a
dedicated helper, which is irrelevant at this scale.

**Risk — resolved 2026-08-26.** The premise was that a launchd-spawned instance of the same
signed binary inherits the app's TCC grants. **Verified empirically:** a Developer ID-signed
probe registered via `SMAppService` produced byte-identical access from its launchd-spawned
agent and its GUI self, with both more restricted than the shell that launched them — so TCC
was genuinely enforcing and distinguishing identities, not merely absent. The
`SMAppService.daemon` fallback is not needed. Details and remaining caveats in
[M0-FINDINGS §9](M0-FINDINGS.md#9-tcc-inheritance--adr-0006-holds).

---

## ADR-0007: SQLite for persistence, not SwiftData

**Status:** Accepted · 2026-08-26

**Context.** Pomace stores watched directories, settings, scan snapshots, per-file state,
and run history.

**Decision.** SQLite in WAL mode, at
`~/Library/Application Support/Pomace/pomace.sqlite`.

**Why.** The GUI and the headless sweep are **separate concurrent processes** against the
same store. SwiftData and Core Data have no supported cross-process concurrency story;
SQLite in WAL mode does, and it's what the situation actually calls for. Per-file state
tables also get large — hundreds of thousands of rows per snapshot — where explicit
indexing and pruning beat an object graph.

**Costs.** Hand-written schema and migrations. Transaction discipline is on us. Library
choice (GRDB vs. the raw C API) deferred to M0 — GRDB is pleasant but is a dependency in a
project that currently has none.

---

## ADR-0008: Project license open

**Status:** Open · 2026-08-26

**Context.** Pomace's own license is undecided. [ADR-0003](#adr-0003-never-bundle-afsctool)
deliberately preserves the full range of options by keeping afsctool at arm's length.

**Decision.** Deferred. Must be settled before first public distribution.

**Considerations.** MIT/Apache-2.0 if the goal is broad reuse; GPL-3.0 if matching
afsctool's spirit matters; source-available or proprietary if distribution is to be
controlled. Nothing in the architecture forecloses any of these — that's the point.

---

## ADR-0009: Progressive disclosure — automatic by default, every flag reachable

**Status:** Accepted · 2026-08-26

**Context.** afsctool exposes ~20 flags whose interactions are non-obvious and whose wrong
settings range from wasteful to destructive. CompactGUI's approach — surface the options as
controls — produces a UI that only someone who already understands the CLI can operate. But
power users legitimately want the flags, and hiding them permanently would make Pomace less
capable than the tool it wraps.

**Decision.** Three tiers of disclosure:

1. **Default path — no options at all.** Add a folder, see the projected saving, press
   Compress. Every flag is computed from the machine, the volume, and the directory's
   contents.
2. **Intent, not mechanism.** A single control in the directory inspector — *Automatic* /
   *Maximum savings* / *Fastest* — expressing a desired outcome. It maps onto a whole
   coordinated preset (compressor, level, threshold), never a single flag.
3. **Settings → Advanced.** Every flag, per-directory, following Xcode's build-settings
   model: each row shows the automatically computed value **and the reason it was chosen**,
   with an override control that visibly marks the row as overridden and offers one-click
   revert. A "Reset all to automatic" action restores the lot.

**Why.** Tier 3's real value is diagnostic, not configurative. A user who wants to know
*why* Pomace picked 4 threads and LZFSE can see the reasoning, which builds the trust the
product depends on — and the same pane happens to let them override it. Apple precedent for
the pattern: Time Machine's single switch plus "Options…", Safari's Advanced tab, Xcode's
build-settings Levels view showing where each value originated.

Overrides are **per-directory, not global**, because the correct settings for a video
library and a source tree genuinely differ.

**Costs.** Every auto-tuned flag needs a human-readable justification string, and those must
stay accurate as the rules evolve — a tested property, not a comment. Three tiers is more UI
surface than one, and the intent control risks being a fourth thing to explain if its
wording drifts toward mechanism.

**Not exposed at any tier:** `-n` (disables verification) and `-L` (afsctool's own help
calls it "not recommended"). These are safety properties, not preferences. See
[SAFETY.md §4](SAFETY.md#4-operational-rules).

---

## ADR-0010: Choose the compressor by measuring the directory, not by static default

**Status:** Accepted · 2026-08-26

**Context.** No single compressor wins everywhere. Ratio and speed vary substantially by
content type, and the right answer for a source tree differs from a photo library. A static
default is a guess applied uniformly.

**Decision.** In *Automatic* mode, Pomace samples a bounded set of representative files from
the target directory, compresses them in memory with each candidate compressor, measures
real ratio and throughput, and selects a winner **for that directory** — recording the
measurement so the user can see what was tested and why it chose. The choice is persisted
per watched directory so re-sweeps stay consistent. LZFSE is the fallback when sampling is
inconclusive or the sample is too small.

**Why.** This is the concrete meaning of "it just works," and it is something no CLI user
does by hand — it's too tedious to be worth it manually and trivial to automate. It also
produces a genuinely useful negative result: a directory of already-compressed media will
measure as near-zero savings, and Pomace can say "there's nothing to gain here" instead of
burning an hour of CPU to reclaim 0.4%.

**Costs.** Sampling costs time before the real run starts — must be bounded and cancellable,
and skipped for small directories where it would dominate. Sample representativeness is a
real problem for heterogeneous trees; cohort by extension rather than sampling uniformly.
The estimator needs snapshot tests or it will silently drift.

---

## ADR-0011: LZFSE default, not ZLIB-9

**Status:** Accepted · 2026-08-26

**Context.** afsctool's default compressor is ZLIB **[verified — decmpfs type 4]**, and the
`-9` level flag applies to ZLIB only. The reference flag set this project was calibrated
against uses `-9`, so the question is whether maximum ZLIB is the right thing to aim at.

**Decision.** LZFSE is the fallback default and the expected common winner. ZLIB is selected
only when per-directory measurement ([ADR-0010](#adr-0010-choose-the-compressor-by-measuring-the-directory-not-by-static-default))
shows it winning materially, and level 9 is applied only in that case.

**Why.** Measured on a 1.3 GB mixed corpus ([DEFAULTS.md §1.1](DEFAULTS.md#11-compressor)):
LZFSE reached 65.6% savings at 354 MB/s; ZLIB-9 reached 66.2% at 56 MB/s. **0.6 percentage
points for 6.4× the time.** ZLIB-9 against ZLIB-5 is worse still — 0.1 points for 3.3× the
time — which means the level knob is very nearly inert across its useful range.

Compression is paid once; decompression is paid on every subsequent read, and LZFSE is
substantially faster there. The ratio comparison therefore understates the case.

**Costs.** LZFSE (decmpfs types 11/12) requires macOS 10.11+ to read. Irrelevant for our
deployment target, but a volume compressed by Pomace and later mounted on something ancient
would not read those files transparently. Document it; don't design around it.

The 0.6 points are real and someone will want them. That is what *Maximum savings* mode is
for — it exists so the default doesn't have to compromise.

**Caveat.** Single machine, single corpus, warm cache, one run per configuration. Directionally
strong, not authoritative. [DEFAULTS.md §6](DEFAULTS.md#6-what-m0-must-re-measure) lists what
M0 re-measures.
