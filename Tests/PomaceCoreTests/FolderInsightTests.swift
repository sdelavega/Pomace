import Testing
import Foundation
@testable import PomaceCore

// Exclusions, savings estimates, re-expansion analysis and history retention (1.2).

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pomace-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func temporaryStore() throws -> (Store, URL) {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pomace-store-\(UUID().uuidString).sqlite")
    return (try Store(url: url), url)
}

private func removeStore(_ url: URL) {
    for suffix in ["", "-shm", "-wal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
}

@Suite("user exclusions")
struct UserExclusionTests {

    func facts(_ path: String) -> FileFacts {
        FileFacts(path: path, logicalSize: 100_000, physicalSize: 102_400, isCompressed: false,
                  type: nil, rawType: nil, decmpfsXattrSize: 0, linkCount: 1, isRegularFile: true,
                  inode: 1, allocatedBlocks: 102_400)
    }

    @Test("patterns are normalized and slashes inside them are refused")
    func normalization() {
        #expect(SafetyRules.normalizedExclusion("  node_modules/ ") == "node_modules")
        #expect(SafetyRules.normalizedExclusion("*.log") == "*.log")
        #expect(SafetyRules.normalizedExclusion("a/b") == nil)
        #expect(SafetyRules.normalizedExclusion("   ") == nil)
        #expect(SafetyRules.normalizedExclusion("..") == nil)
    }

    @Test("a pattern matches files and folders below the root, case-insensitively")
    func matching() {
        let rules = SafetyRules(userExclusions: ["node_modules", "*.LOG"], root: "/Users/alex/Code")
        #expect(rules.matchingExclusion("/Users/alex/Code/app/node_modules/x/index.js") == "node_modules")
        #expect(rules.matchingExclusion("/Users/alex/Code/build.log") == "*.LOG")
        #expect(rules.matchingExclusion("/Users/alex/Code/app/main.swift") == nil)
        #expect(rules.isExcluded(facts("/Users/alex/Code/app/node_modules/x/index.js")))
        #expect(rules.evaluate(facts("/Users/alex/Code/a.log")).contains(.userExcluded("*.LOG")))
    }

    @Test("components above the root are never matched")
    func aboveRoot() {
        let rules = SafetyRules(userExclusions: ["Users", "alex"], root: "/Users/alex/Code")
        #expect(rules.matchingExclusion("/Users/alex/Code/notes.txt") == nil)
    }

    @Test("exclusions are a hard exclusion, never an override")
    func hardExclusion() {
        #expect(SafetyReason.userExcluded("*.log").isHardExclusion)
        #expect(SafetyRules().matchingExclusion("/anything/node_modules/x") == nil)
    }
}

@Suite("savings estimator")
struct SavingsEstimatorTests {

    struct Fixed: RandomNumberGenerator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    @Test("samples stay within the file and byte budgets")
    func budgets() {
        let candidates = (0..<1000).map { SampleCandidate(path: "/f\($0)", size: Int64(($0 % 50 + 1) * 1_000_000)) }
        var generator = Fixed()
        let sample = SavingsEstimator.chooseSample(from: candidates, using: &generator)
        #expect(!sample.isEmpty)
        #expect(sample.count <= SavingsEstimator.maxSampleFiles)
        let copied = sample.reduce(Int64(0)) { $0 + min($1.size, SavingsEstimator.maxBytesPerFile) }
        #expect(copied <= SavingsEstimator.maxSampleBytes)
        #expect(Set(sample.map(\.path)).count == sample.count)
    }

    @Test("LZFSE is kept unless another compressor clearly beats it")
    func recommendation() {
        #expect(SavingsEstimator.recommend([.init(compressor: "lzfse", savedFraction: 0.40),
                                            .init(compressor: "zlib", savedFraction: 0.42)]) == "lzfse")
        #expect(SavingsEstimator.recommend([.init(compressor: "lzfse", savedFraction: 0.40),
                                            .init(compressor: "zlib", savedFraction: 0.50)]) == "zlib")
        #expect(SavingsEstimator.recommend([]) == nil)
    }

    @Test("estimates come from copies and leave the originals untouched")
    func copiesOnly() throws {
        let dir = try temporaryDirectory("estimate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("data.txt")
        let contents = Data(repeating: 65, count: 64 * 1024)
        try contents.write(to: file)
        let size = try #require(FileInspector.inspect(file.path)).physicalSize

        let capabilities = ToolCapabilities(version: nil, compressors: ["lzfse", "zlib"], supportsVerify: true,
                                            supportsLevel: false, supportsMinimumRatio: true, rawUsage: "")
        let installation = ToolInstallation(source: .custom("/nonexistent/applesauce"),
                                            capabilities: capabilities, sha256: nil)
        let invoked = LockedPaths()
        let estimate = try #require(SavingsEstimator.estimate(
            candidates: [SampleCandidate(path: file.path, size: size)], eligibleBytes: size * 10,
            root: dir.path, installation: installation,
            runCompressor: { _, arguments in
                invoked.add(arguments)
                return Subprocess.Output(stdout: "", stderr: "", code: 0)
            }))
        // A compressor that does nothing saves nothing, with either algorithm.
        #expect(estimate.measurements.map(\.compressor) == ["lzfse", "zlib"])
        #expect(estimate.recommendedReclaim == 0)
        #expect(estimate.recommendedCompressor == "lzfse")
        #expect(try Data(contentsOf: file) == contents)
        for arguments in invoked.all {
            #expect(arguments.contains("--verify"))
            #expect(!arguments.contains(file.path))
        }
    }

    final class LockedPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [[String]] = []
        func add(_ value: [String]) { lock.lock(); values.append(value); lock.unlock() }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return values }
    }
}

@Suite("re-expansion report")
struct ExpansionReportTests {

    func snapshot(_ day: Double, files: Int, compressed: Int, reclaimed: Int64) -> Store.SnapshotSummary {
        Store.SnapshotSummary(scannedAt: Date(timeIntervalSince1970: day * 86_400), files: files,
                              logicalBytes: 0, physicalBytes: 0, compressedFiles: compressed,
                              compressedLogicalBytes: reclaimed * 2, compressedPhysicalBytes: reclaimed,
                              eligibleFiles: 0)
    }

    @Test("compression lost between scans is counted and suggests a manual schedule")
    func churn() {
        let history = [
            snapshot(0, files: 100, compressed: 100, reclaimed: 100_000_000),
            snapshot(1, files: 100, compressed: 60, reclaimed: 60_000_000),
            snapshot(2, files: 100, compressed: 100, reclaimed: 100_000_000),
            snapshot(3, files: 100, compressed: 50, reclaimed: 50_000_000),
            snapshot(4, files: 100, compressed: 100, reclaimed: 100_000_000),
            snapshot(5, files: 100, compressed: 70, reclaimed: 70_000_000),
        ]
        let report = ExpansionReport.analyze(history)
        #expect(report.reExpandedFiles == 120)
        #expect(report.reExpandedBytes == 120_000_000)
        #expect(report.expandingIntervals == 3)
        #expect(report.suggestsManualSchedule)
    }

    @Test("deleted files are not re-expansion")
    func deletions() {
        let report = ExpansionReport.analyze([
            snapshot(0, files: 100, compressed: 100, reclaimed: 100_000_000),
            snapshot(1, files: 60, compressed: 60, reclaimed: 60_000_000),
        ])
        #expect(report.reExpandedFiles == 0)
        #expect(report.reExpandedBytes == 0)
    }

    @Test("an interval containing the user's Decompress is skipped")
    func decompression() {
        let report = ExpansionReport.analyze([
            snapshot(0, files: 100, compressed: 100, reclaimed: 100_000_000),
            snapshot(2, files: 100, compressed: 0, reclaimed: 0),
        ], decompressions: [Date(timeIntervalSince1970: 86_400)])
        #expect(report.reExpandedBytes == 0)
        #expect(report.intervalsCompared == 1)
        #expect(!report.suggestsManualSchedule)
    }
}

@Suite("folder settings and retention")
struct RetentionTests {

    @Test("exclusions and the measured compressor persist per folder")
    func folderSettings() throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(url) }
        try store.addWatchedDirectory(path: "/tmp/pomace-settings")
        try store.updateExclusions(path: "/tmp/pomace-settings", exclusions: ["node_modules", "*.log"])
        try store.updateMeasuredCompressor(path: "/tmp/pomace-settings", compressor: "zlib")
        let entry = try #require(store.watched().first)
        #expect(entry.exclusions == ["node_modules", "*.log"])
        #expect(entry.measuredCompressor == "zlib")
        #expect(entry.rules.matchingExclusion("/tmp/pomace-settings/a/node_modules/b") == "node_modules")
    }

    @Test("pruning keeps the newest completed sweep and drops orphans")
    func prune() throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(url) }
        let path = "/tmp/pomace-prune"
        try store.addWatchedDirectory(path: path)
        let now = Date()
        let old = now.addingTimeInterval(-Store.retentionInterval - 86_400)
        try store.recordSweep(path: path, startedAt: old, duration: 1)
        try store.recordSweep(path: path, startedAt: old.addingTimeInterval(60), duration: 0, deferral: .onBattery)
        try store.recordSweep(path: path, startedAt: now, duration: 0, deferral: .onBattery)
        try store.recordSweep(path: "/tmp/pomace-removed", startedAt: now, duration: 1)
        try store.recordManualRun(path: path, startedAt: now, operation: .decompress)

        try store.prune(now: now)

        let runs = try store.sweepHistory(path: path)
        #expect(runs.count == 2)
        #expect(try store.lastCompletedSweep(path: path) == Date(timeIntervalSince1970: old.timeIntervalSince1970))
        #expect(try store.sweepHistory(path: "/tmp/pomace-removed").isEmpty)
        #expect(try store.decompressions(path: path).count == 1)
    }

    @Test("removing a folder forgets its history")
    func removal() throws {
        let (store, url) = try temporaryStore()
        defer { removeStore(url) }
        let path = "/tmp/pomace-remove"
        try store.addWatchedDirectory(path: path)
        try store.recordSweep(path: path, startedAt: Date(), duration: 1)
        try store.recordManualRun(path: path, startedAt: Date(), operation: .decompress)
        try store.removeWatchedDirectory(path: path)
        #expect(try store.sweepHistory(path: path).isEmpty)
        #expect(try store.decompressions(path: path).isEmpty)
    }

    @Test("the mutation log rotates and diagnostics read across both files")
    func logRotation() throws {
        let dir = try temporaryDirectory("log")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mutations.log")
        let first = MutationLog(url: url, rotationSize: 64)
        for i in 0..<5 { first.note("first \(i)") }
        let second = MutationLog(url: url, rotationSize: 64)
        second.note("second")

        #expect(FileManager.default.fileExists(atPath: MutationLog.rotatedURL(for: url).path))
        let lines = DiagnosticsFiles.logLines(at: url, limit: 3)
        #expect(lines.count == 3)
        #expect(lines.last?.hasSuffix("NOTE second") == true)
        #expect(lines.first?.hasSuffix("NOTE first 3") == true)
    }
}
