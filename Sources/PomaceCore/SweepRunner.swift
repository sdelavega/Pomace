import Foundation

public struct SweepReport: Sendable {
    public var path: String
    public var deferral: SweepDeferral?
    public var filesCompressed = 0
    public var filesFailed = 0
    public var bytesReclaimed: Int64 = 0
    public var error: CompressionEngineError?
    public var duration: TimeInterval = 0
    public var wasIncremental = false
    public var candidatesConsidered = 0
}

/// Runs due sweeps. Used by the headless `--sweep-all` mode and by "Sweep Now" in the UI.
public struct SweepRunner: Sendable {

    /// A full re-verification runs at least this often, even when incremental sweeps have
    /// been keeping up. Incremental passes only see files whose mtime moved; anything
    /// decompressed by a tool that preserves mtime would otherwise never be noticed.
    public static let fullVerificationInterval: TimeInterval = 30 * 24 * 3600

    /// Overlap applied to the incremental cutoff, to cover whole-second mtime granularity.
    public static let mtimeGracePeriod: TimeInterval = 2

    let store: Store
    let log: MutationLog

    /// Safety rules are per folder (`Store.WatchedDirectory.rules`), so none are injected here.
    public init(store: Store, log: MutationLog = MutationLog(),
                lockURL: URL = SweepLock.defaultURL,
                checkPreconditions: @escaping @Sendable (String) -> SweepDeferral? = { SweepPreconditions.check(root: $0) }) {
        self.store = store
        self.log = log
        self.lockURL = lockURL
        self.checkPreconditions = checkPreconditions
    }

    private let lockURL: URL
    private let checkPreconditions: @Sendable (String) -> SweepDeferral?

    /// Sweeps every directory that is due. Returns one report per directory considered.
    public func sweepAll(now: Date = Date(), force: Bool = false) async -> [SweepReport] {
        guard let lock = SweepLock.acquire(at: lockURL) else {
            log.note("sweep skipped — another sweep holds the lock")
            return []
        }
        defer { lock.release() }

        guard let installation = CompressorTool.resolve(
            customPath: UserDefaults.standard.string(forKey: CompressorTool.customPathDefaultsKey)).installation else {
            log.note("sweep skipped — \(CompressorTool.displayName) unavailable")
            return []
        }

        // An unreadable folder list must not read as "nothing to do": that would silently
        // disable every scheduled sweep until the next lucky wake.
        let directories: [Store.WatchedDirectory]
        do { directories = try store.watched() } catch {
            log.note("sweep skipped — history unavailable: \(error)")
            return []
        }
        var reports: [SweepReport] = []

        for dir in directories {
            // An unreadable history must not read as "never swept": that would make the
            // folder due on every wake and force a full pass. Try again next wake.
            let lastRun: Date?
            do { lastRun = try store.lastCompletedSweep(path: dir.path) } catch {
                log.note("sweep skipped for \(dir.path) — history unavailable: \(error)")
                continue
            }
            guard force || dir.schedule.isDue(lastRun: lastRun, now: now) else { continue }
            reports.append(await sweepUnlocked(dir, installation: installation, lastRun: lastRun, now: now))
        }
        // Each wake may add a deferral row; keep history bounded (see `Store.prune`).
        do { try store.prune(now: now) } catch { log.note("history pruning failed: \(error)") }
        return reports
    }

    public func sweep(_ dir: Store.WatchedDirectory,
                      installation: ToolInstallation,
                      lastRun: Date?,
                      now: Date = Date()) async -> SweepReport {

        guard let lock = SweepLock.acquire(at: lockURL) else {
            var report = SweepReport(path: dir.path)
            report.error = .alreadyRunning
            return report
        }
        defer { lock.release() }
        return await sweepUnlocked(dir, installation: installation, lastRun: lastRun, now: now)
    }

    private func sweepUnlocked(_ dir: Store.WatchedDirectory,
                               installation: ToolInstallation,
                               lastRun: Date?,
                               now: Date) async -> SweepReport {
        var report = SweepReport(path: dir.path)
        let started = Date()

        if let deferral = checkPreconditions(dir.path) {
            report.deferral = deferral
            report.duration = Date().timeIntervalSince(started)
            log.note("deferred \(dir.path): \(deferral.rawValue)")
            _ = try? store.recordSweep(path: dir.path, startedAt: started, duration: report.duration,
                                       deferral: deferral)
            return report
        }

        // Incremental unless a full verification is due. Incremental only considers files
        // touched since the last sweep, which is what makes a nightly pass over a large
        // library cheap.
        let needsFullPass = lastRun.map { now.timeIntervalSince($0) >= Self.fullVerificationInterval } ?? true
        report.wasIncremental = !needsFullPass
        // Back the cutoff off by a second. st_mtimespec is compared at second granularity, so
        // a file written in the same second the last sweep started would otherwise be
        // invisible until the next full pass — up to a month later. Re-considering a few
        // already-compressed files costs nothing; they are filtered out anyway.
        let cutoff = needsFullPass ? nil : lastRun?.addingTimeInterval(-Self.mtimeGracePeriod)

        // One statfs per sweep, not one per file.
        let volume = VolumeContext.probe(path: dir.path)
        // The folder's own exclusions apply on top of the built-in rules.
        let rules = dir.rules
        var candidates: [String] = []
        // Eligible-but-uncompressed data across the whole tree, not just changed files: the
        // compression baseline recorded below is measured from it (see `Degradation`).
        var eligibleLogical: Int64 = 0
        let walk = DirectoryWalker.walkFTS(dir.path) { facts in
            guard facts.isRegularFile, !facts.isCompressed else { return }
            guard !rules.isExcluded(facts, volume: volume) else { return }
            eligibleLogical += facts.logicalSize
            if let cutoff {
                var st = stat()
                guard lstat(facts.path, &st) == 0 else { return }
                // ctime as well as mtime: Finder copies, `cp -p`, `mv` and archive extraction
                // all preserve mtime, so files arriving that way looked older than the last
                // sweep and waited up to a month for the next full pass.
                let changed = max(st.st_mtimespec.tv_sec, st.st_ctimespec.tv_sec)
                guard Date(timeIntervalSince1970: TimeInterval(changed)) > cutoff else { return }
            }
            candidates.append(facts.path)
        }
        report.candidatesConsidered = candidates.count
        // A cancelled walk saw only part of the tree; its totals must not become a baseline.
        let walkCompleted = !Task.isCancelled

        guard !candidates.isEmpty else {
            report.duration = Date().timeIntervalSince(started)
            // A cancelled walk is not a completed sweep: marking it done would advance the
            // cutoff past everything the walk never saw and blind incremental sweeps to
            // those files until the next full pass.
            _ = try? store.recordSweep(path: dir.path, startedAt: started, duration: report.duration,
                                        cancelled: !walkCompleted)
            if walkCompleted {
                recordBaseline(dir.path, compressed: walk.compressedLogical, eligible: eligibleLogical)
            }
            return report
        }

        // Background sweeps take the conservative thread count and stay off the foreground
        // I/O path — the user should never notice this running.
        let plan = CompressionPolicy.plan(
            mode: dir.mode,
            conditions: RuntimeConditions.current(volumePath: dir.path),
            measuredCompressor: dir.measuredCompressor,
            capabilities: installation.capabilities)

        var finished: CompressionOutcome?
        for await event in CompressionEngine.run(operation: .compress, paths: candidates,
                                                 root: dir.path, installation: installation,
                                                 plan: plan, rules: rules, logger: log) {
            switch event {
            case .finished(let outcome):
                finished = outcome
                report.filesCompressed = outcome.filesSucceeded
                report.filesFailed = outcome.realFailures.count
                report.bytesReclaimed = outcome.bytesReclaimed
            case .failed(let message):
                report.error = message
            default: break
            }
        }

        report.duration = Date().timeIntervalSince(started)
        // Cancelled here too: see the empty-candidates branch above.
        _ = try? store.recordSweep(path: dir.path, startedAt: started, duration: report.duration,
                                   filesCompressed: report.filesCompressed,
                                   filesFailed: report.filesFailed,
                                   bytesReclaimed: report.bytesReclaimed,
                                   error: report.error.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) },
                                   cancelled: !walkCompleted)
        // A completed sweep is the folder's new "last compression". What it compressed
        // moves from eligible to compressed; what it declined stays as the eligible floor.
        if walkCompleted, let outcome = finished, !outcome.wasCancelled {
            recordBaseline(dir.path, compressed: walk.compressedLogical + outcome.logicalBytesSucceeded,
                           eligible: max(0, eligibleLogical - outcome.logicalBytesSucceeded))
        } else if walkCompleted, report.error == .nothingToDo {
            recordBaseline(dir.path, compressed: walk.compressedLogical, eligible: eligibleLogical)
        }
        return report
    }

    private func recordBaseline(_ path: String, compressed: Int64, eligible: Int64) {
        let baseline = CompressionBaseline(recordedAt: Date(), compressedLogicalBytes: compressed,
                                           eligibleLogicalBytes: eligible)
        do { try store.setBaseline(path: path, baseline) } catch {
            log.note("baseline not recorded for \(path): \(error)")
        }
    }
}
