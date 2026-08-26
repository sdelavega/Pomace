import Foundation

public struct SweepReport: Sendable {
    public var path: String
    public var deferral: SweepDeferral?
    public var filesCompressed = 0
    public var filesFailed = 0
    public var bytesReclaimed: Int64 = 0
    public var error: String?
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
    let rules: SafetyRules

    public init(store: Store, log: MutationLog = MutationLog(), rules: SafetyRules = SafetyRules()) {
        self.store = store
        self.log = log
        self.rules = rules
    }

    /// Only one sweep may run at a time across every process — the GUI and the launchd agent
    /// are separate processes against the same files.
    static var lockURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomace/sweep.lock")
    }

    static func acquireLock() -> FileHandle? {
        let url = lockURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        guard flock(handle.fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
            try? handle.close()
            return nil
        }
        return handle
    }

    /// Sweeps every directory that is due. Returns one report per directory considered.
    public func sweepAll(now: Date = Date(), force: Bool = false) async -> [SweepReport] {
        guard let lock = Self.acquireLock() else {
            log.note("sweep skipped — another sweep holds the lock")
            return []
        }
        defer { flock(lock.fileDescriptor, LOCK_UN); try? lock.close() }

        guard let installation = CompressorTool.discover(), installation.capabilities.isUsable else {
            log.note("sweep skipped — \(CompressorTool.displayName) unavailable")
            return []
        }

        let directories = (try? store.watched()) ?? []
        var reports: [SweepReport] = []

        for dir in directories {
            let lastRun = try? store.lastCompletedSweep(path: dir.path)
            guard force || dir.schedule.isDue(lastRun: lastRun ?? nil, now: now) else { continue }
            reports.append(await sweep(dir, installation: installation, lastRun: lastRun ?? nil, now: now))
        }
        return reports
    }

    public func sweep(_ dir: Store.WatchedDirectory,
                      installation: ToolInstallation,
                      lastRun: Date?,
                      now: Date = Date()) async -> SweepReport {

        var report = SweepReport(path: dir.path)
        let started = Date()

        if let deferral = SweepPreconditions.check(root: dir.path) {
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

        var candidates: [String] = []
        _ = DirectoryWalker.walkFTS(dir.path) { facts in
            guard facts.isRegularFile, !facts.isCompressed else { return }
            if let cutoff {
                var st = stat()
                guard lstat(facts.path, &st) == 0 else { return }
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                guard mtime > cutoff else { return }
            }
            guard !rules.isExcluded(facts, volume: VolumeContext.probe(path: dir.path)) else { return }
            candidates.append(facts.path)
        }
        report.candidatesConsidered = candidates.count

        guard !candidates.isEmpty else {
            report.duration = Date().timeIntervalSince(started)
            _ = try? store.recordSweep(path: dir.path, startedAt: started, duration: report.duration)
            return report
        }

        // Background sweeps take the conservative thread count and stay off the foreground
        // I/O path — the user should never notice this running.
        let plan = CompressionPolicy.plan(
            mode: dir.mode,
            conditions: RuntimeConditions.current(volumePath: dir.path),
            capabilities: installation.capabilities)

        for await event in CompressionEngine.run(operation: .compress, paths: candidates,
                                                 root: dir.path, installation: installation,
                                                 plan: plan, rules: rules, logger: log) {
            switch event {
            case .finished(let outcome):
                report.filesCompressed = outcome.filesSucceeded
                report.filesFailed = outcome.realFailures.count
                report.bytesReclaimed = outcome.bytesReclaimed
            case .failed(let message):
                report.error = message
            default: break
            }
        }

        report.duration = Date().timeIntervalSince(started)
        _ = try? store.recordSweep(path: dir.path, startedAt: started, duration: report.duration,
                                   filesCompressed: report.filesCompressed,
                                   filesFailed: report.filesFailed,
                                   bytesReclaimed: report.bytesReclaimed,
                                   error: report.error)
        return report
    }
}
