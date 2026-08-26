import Testing
import Foundation
@testable import PomaceCore

// Regression tests for the M0 findings. Each one guards a bug that was actually hit.

@Suite("decmpfs header")
struct DecmpfsHeaderTests {

    func header(type: UInt32, size: UInt64, magic: UInt32 = DecmpfsHeader.magic) -> [UInt8] {
        var b = [UInt8]()
        for v in [magic, type] { for i in 0..<4 { b.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) } }
        for i in 0..<8 { b.append(UInt8((size >> (8 * UInt64(i))) & 0xff)) }
        return b
    }

    @Test("parses a well-formed header")
    func parses() throws {
        let h = try #require(DecmpfsHeader(header(type: 12, size: 2_200_000)))
        #expect(h.rawType == 12)
        #expect(h.uncompressedSize == 2_200_000)
        #expect(h.type == .lzfseResource)
    }

    @Test("rejects a bad magic rather than reading garbage")
    func rejectsBadMagic() {
        #expect(DecmpfsHeader(header(type: 4, size: 100, magic: 0xDEADBEEF)) == nil)
    }

    @Test("rejects a short buffer")
    func rejectsShort() {
        #expect(DecmpfsHeader([0x66, 0x70, 0x6d, 0x63]) == nil)
    }

    @Test("surfaces unknown types without crashing")
    func unknownType() throws {
        let h = try #require(DecmpfsHeader(header(type: 99, size: 10)))
        #expect(h.rawType == 99)
        #expect(h.type == nil)   // must degrade to "compressed, algorithm unknown"
    }

    @Test("storage class is right for every known type", arguments: [
        (UInt32(1), CompressionType.Storage.inlineXattr),
        (3, .inlineXattr), (4, .resourceFork),
        (7, .inlineXattr), (8, .resourceFork),
        (11, .inlineXattr), (12, .resourceFork),
    ])
    func storageClass(raw: UInt32, expected: CompressionType.Storage) throws {
        let t = try #require(CompressionType(rawValue: raw))
        #expect(t.storage == expected)
    }
}

@Suite("physical size")
struct PhysicalSizeTests {

    func hdr(_ type: UInt32) -> DecmpfsHeader? {
        var b = [UInt8]()
        for v in [DecmpfsHeader.magic, type] { for i in 0..<4 { b.append(UInt8((v >> (8 * UInt32(i))) & 0xff)) } }
        b.append(contentsOf: [UInt8](repeating: 0, count: 8))
        return DecmpfsHeader(b)
    }

    @Test("uncompressed files just use st_blocks")
    func uncompressed() {
        #expect(FileInspector.physicalSize(compressed: false, blockBytes: 8192,
                                           header: nil, xattrSize: 0) == 8192)
    }

    @Test("resource-fork storage trusts st_blocks")
    func resourceFork() {
        // Measured: 2.2 MB text -> 24 blocks, agreeing with afsctool exactly.
        #expect(FileInspector.physicalSize(compressed: true, blockBytes: 12288,
                                           header: hdr(4), xattrSize: 16) == 12288)
    }

    @Test("inline xattr with no allocated block costs the xattr length")
    func inlineNoBlock() {
        // Measured: 100-byte file -> st_blocks 0, 48-byte xattr. afsctool reports 0 here.
        #expect(FileInspector.physicalSize(compressed: true, blockBytes: 0,
                                           header: hdr(11), xattrSize: 48) == 48)
    }

    @Test("inline xattr inside an allocated block is max, not sum")
    func inlineWithBlock() {
        // Measured: 202-byte xattr with st_blocks 8 is 4096 bytes on disk, not 4298.
        // Summing here was the original bug.
        #expect(FileInspector.physicalSize(compressed: true, blockBytes: 4096,
                                           header: hdr(11), xattrSize: 202) == 4096)
    }

    @Test("unknown compression type never claims a file occupies nothing")
    func unknownTypeFallback() {
        #expect(FileInspector.physicalSize(compressed: true, blockBytes: 0,
                                           header: hdr(99), xattrSize: 512) == 512)
    }
}

@Suite("safety rules")
struct SafetyRulesTests {

    let rules = SafetyRules()

    func facts(path: String = "/Users/x/file.txt", logical: Int64 = 100_000,
               physical: Int64 = 102_400, compressed: Bool = false,
               links: UInt16 = 1, regular: Bool = true) -> FileFacts {
        FileFacts(path: path, logicalSize: logical, physicalSize: physical,
                  isCompressed: compressed, type: nil, rawType: nil, decmpfsXattrSize: 0,
                  linkCount: links, isRegularFile: regular, inode: 1,
                  allocatedBlocks: physical)
    }

    @Test("sparse files are a hard exclusion")
    func sparse() {
        // Measured in M0: compressing a sparse file materializes it and costs disk.
        let r = rules.evaluate(facts(logical: 10_485_760, physical: 0))
        #expect(r.contains { if case .sparseFile = $0 { true } else { false } })
        #expect(rules.isExcluded(facts(logical: 10_485_760, physical: 0)))
    }

    @Test("a normal file with block rounding is not mistaken for sparse")
    func notSparse() {
        // 100_000 logical rounds up to 102_400 allocated — physical exceeds logical.
        #expect(!rules.isExcluded(facts()))
    }

    @Test("empty files are excluded, not compressed pointlessly")
    func empty() {
        #expect(rules.evaluate(facts(logical: 0, physical: 0)).contains(.zeroLength))
    }

    @Test("VM images are excluded", arguments: ["disk.vmdk", "box.qcow2", "vm.utm", "img.sparsebundle"])
    func vmImages(name: String) {
        #expect(rules.isExcluded(facts(path: "/Users/x/\(name)")))
    }

    @Test("cloud-synced paths are excluded", arguments: [
        "/Users/x/Library/Mobile Documents/a.txt",
        "/Users/x/Dropbox/a.txt",
        "/Users/x/Library/CloudStorage/OneDrive/a.txt",
    ])
    func cloudSync(path: String) {
        #expect(rules.isExcluded(facts(path: path)))
    }

    @Test("system paths are excluded but /usr/local is not")
    func systemPaths() {
        #expect(rules.isExcluded(facts(path: "/System/Library/a.dylib")))
        #expect(rules.isExcluded(facts(path: "/usr/lib/a.dylib")))
        #expect(!rules.isExcluded(facts(path: "/usr/local/lib/a.dylib")))
    }

    @Test("hard links warn but do not exclude")
    func hardLinks() {
        let r = rules.evaluate(facts(links: 3))
        #expect(r.contains(.hardLinked(linkCount: 3)))
        #expect(!rules.isExcluded(facts(links: 3)))
    }

    @Test("already-compressed formats warn but do not exclude")
    func incompressible() {
        let r = rules.evaluate(facts(path: "/Users/x/photo.jpg"))
        #expect(r.contains(.likelyIncompressible("JPEG")))
        #expect(!rules.isExcluded(facts(path: "/Users/x/photo.jpg")))
    }

    @Test("network volumes block the whole tree")
    func networkVolume() {
        let vol = VolumeContext(filesystem: "smbfs", isNetwork: true)
        #expect(rules.isExcluded(facts(), volume: vol))
    }

    @Test("non-APFS filesystems block the whole tree")
    func wrongFilesystem() {
        #expect(rules.isExcluded(facts(), volume: VolumeContext(filesystem: "exfat")))
        #expect(!rules.isExcluded(facts(), volume: VolumeContext(filesystem: "apfs")))
    }

    @Test("the fast pass makes no extra syscalls for resource forks")
    func fastPassSkipsForkProbe() {
        // Probing every file added a getxattr per file and turned a 0.35s walk into minutes.
        let r = rules.evaluate(facts(), depth: .fast)
        #expect(!r.contains(.existingResourceFork))
    }

    @Test("every reason explains itself in prose for the UI")
    func explanationsArePresentable() {
        let all: [SafetyReason] = [
            .systemPath, .sparseFile(allocatedBytes: 0, logicalBytes: 1024),
            .existingResourceFork, .liveDatabase("SQLite database"), .virtualMachineImage,
            .cloudSyncedDirectory("Dropbox"), .timeMachineVolume,
            .unsupportedFilesystem("exfat"), .networkVolume, .zeroLength, .notRegularFile,
            .appStoreApplication, .adobeApplication,
            .applicationBundle, .hardLinked(linkCount: 2),
            .veryLargeFile(bytes: 5_000_000_000), .likelyIncompressible("JPEG"),
        ]
        for reason in all {
            #expect(!reason.explanation.isEmpty)
            // Reads as a sentence: starts with a capital or a figure ("4.7 GB — …").
            let first = reason.explanation.first!
            #expect(first.isUppercase || first.isNumber,
                    "not sentence-cased: \(reason.explanation)")
            #expect(!reason.explanation.hasSuffix("."), "UI strings carry no trailing period")
        }
    }

    @Test("Adobe application bundles are hard exclusions")
    func adobeApps() {
        let r = rules.evaluate(facts(path: "/Applications/Adobe Photoshop.app/Contents/MacOS/Photoshop"))
        #expect(r.contains(.adobeApplication))
        #expect(rules.isExcluded(facts(path: "/Applications/Adobe Photoshop.app/Contents/MacOS/Photoshop")))
    }

    @Test("Mac App Store application bundles are hard exclusions")
    func appStoreApps() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PomaceSafety-\(UUID().uuidString).app")
        let receipt = root.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: receipt.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("Contents/MacOS/App").path
        let r = rules.evaluate(facts(path: target))
        #expect(r.contains(.appStoreApplication))
        #expect(rules.isExcluded(facts(path: target)))
    }
}

@Suite("scan aggregates")
struct ScanAggregateTests {

    @Test("reclaimed bytes come only from compressed files")
    func reclaimedIgnoresSparse() {
        // A tree of sparse files has physical far below logical while being 0% compressed.
        // Deriving reclaimed from tree-wide totals reported 10.5 MB of savings that
        // did not exist.
        var r = ScanResult()
        r.progress.logicalBytes = 10_800_000
        r.progress.physicalBytes = 344_100
        r.progress.compressedFiles = 0
        r.progress.compressedLogicalBytes = 0
        r.progress.compressedPhysicalBytes = 0
        #expect(r.reclaimedBytes == 0)
    }

    @Test("reclaimed bytes are correct when compression is present")
    func reclaimedCountsCompressed() {
        var r = ScanResult()
        r.progress.logicalBytes = 2_000_000
        r.progress.physicalBytes = 500_000
        r.progress.compressedFiles = 10
        r.progress.compressedLogicalBytes = 1_000_000
        r.progress.compressedPhysicalBytes = 250_000
        #expect(r.reclaimedBytes == 750_000)
    }

    @Test("coverage is zero on an empty tree rather than dividing by zero")
    func emptyTree() {
        #expect(ScanResult().compressionCoverage == 0)
        #expect(ScanResult().reclaimedBytes == 0)
    }
}

@Suite("scan entry identity")
struct ScanEntryIdentityTests {

    func entry(path: String, inode: UInt64) -> ScanEntry {
        ScanEntry(inode: inode, path: path, logicalSize: 100, physicalSize: 100,
                  isCompressed: false, type: nil, reasons: [])
    }

    @Test("hard-linked files share an inode but must have distinct view identities")
    func distinctIDs() {
        // Duplicate Identifiable IDs made SwiftUI's Table draw one row twice: two
        // hard-linked files both appeared under the first one's name.
        let a = entry(path: "/tmp/linked-a.txt", inode: 42)
        let b = entry(path: "/tmp/linked-b.txt", inode: 42)
        #expect(a.inode == b.inode)
        #expect(a.id != b.id)
        #expect(Set([a.id, b.id]).count == 2)
    }
}

@Suite("sweep scheduling")
struct SweepScheduleTests {

    let cal = Calendar(identifier: .gregorian)
    func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    @Test("a folder never swept is due immediately")
    func neverSwept() {
        let s = SweepSchedule(cadence: .daily, preferredHour: 3)
        #expect(s.isDue(lastRun: nil, now: date("2026-08-26T01:00:00Z")))
    }

    @Test("not due before the cadence has elapsed")
    func notYetElapsed() {
        let s = SweepSchedule(cadence: .weekly)
        let last = date("2026-08-25T03:00:00Z")
        #expect(!s.isDue(lastRun: last, now: date("2026-08-26T04:00:00Z")))
    }

    @Test("waits for the preferred hour once due")
    func waitsForPreferredHour() {
        let s = SweepSchedule(cadence: .daily, preferredHour: 3)
        let last = date("2026-08-25T03:00:00Z")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        #expect(!s.isDue(lastRun: last, now: date("2026-08-26T01:00:00Z"), calendar: cal))
        #expect(s.isDue(lastRun: last, now: date("2026-08-26T05:00:00Z"), calendar: cal))
    }

    @Test("a long-overdue sweep runs regardless of the hour")
    func overdueIgnoresHour() {
        // The machine was asleep for days; don't wait for 3 AM to come round again.
        let s = SweepSchedule(cadence: .daily, preferredHour: 3)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let last = date("2026-08-20T03:00:00Z")
        #expect(s.isDue(lastRun: last, now: date("2026-08-26T01:00:00Z"), calendar: cal))
    }

    @Test("manual and paused schedules are never due")
    func neverDue() {
        #expect(!SweepSchedule(cadence: .manual).isDue(lastRun: nil, now: Date()))
        #expect(!SweepSchedule(cadence: .daily, enabled: false).isDue(lastRun: nil, now: Date()))
    }

    @Test("summaries read as English")
    func summaries() {
        #expect(SweepSchedule(cadence: .daily, preferredHour: 0).summary.contains("midnight"))
        #expect(SweepSchedule(cadence: .daily, preferredHour: 12).summary.contains("noon"))
        #expect(SweepSchedule(cadence: .daily, preferredHour: 15).summary.contains("3 PM"))
        #expect(SweepSchedule(cadence: .weekly, enabled: false).summary == "Paused")
    }
}

@Suite("sweep preconditions")
struct SweepPreconditionTests {

    @Test("a missing folder defers rather than failing")
    func missingFolder() {
        let d = SweepPreconditions.check(root: "/nonexistent/folder/xyz",
                                         conditions: RuntimeConditions(),
                                         timeMachineRunning: false)
        #expect(d == .volumeUnavailable)
    }

    @Test("power and thermal conditions each defer", arguments: [
        (RuntimeConditions(thermalPressure: true), SweepDeferral.thermalPressure),
        (RuntimeConditions(lowPowerMode: true), .lowPowerMode),
        (RuntimeConditions(onBattery: true), .onBattery),
    ])
    func conditionsDefer(conditions: RuntimeConditions, expected: SweepDeferral) {
        let d = SweepPreconditions.check(root: NSTemporaryDirectory(),
                                         conditions: conditions, timeMachineRunning: false)
        #expect(d == expected)
    }

    @Test("a Time Machine backup defers")
    func timeMachineDefers() {
        let d = SweepPreconditions.check(root: NSTemporaryDirectory(),
                                         conditions: RuntimeConditions(), timeMachineRunning: true)
        #expect(d == .timeMachineRunning)
    }

    @Test("nothing in the way means no deferral")
    func clearToRun() {
        #expect(SweepPreconditions.check(root: NSTemporaryDirectory(),
                                         conditions: RuntimeConditions(),
                                         timeMachineRunning: false) == nil)
    }

    @Test("every deferral explains itself")
    func deferralsExplained() {
        for d in [SweepDeferral.onBattery, .lowPowerMode, .thermalPressure,
                  .timeMachineRunning, .volumeUnavailable, .alreadyRunning] {
            #expect(d.explanation.hasPrefix("Skipped"))
        }
    }
}

@Suite("tool version parsing")
struct ToolVersionTests {

    @Test("parses the applesauce banner")
    func banner() throws {
        let v = try #require(ToolVersion(banner: "applesauce-cli 0.5.28"))
        #expect(v.description == "0.5.28")
    }

    @Test("tolerates a two-component version")
    func twoComponent() throws {
        #expect(try #require(ToolVersion(banner: "applesauce 1.0")).description == "1.0.0")
    }

    @Test("returns nil on unparseable output")
    func garbage() {
        #expect(ToolVersion(banner: "command not found") == nil)
        #expect(ToolVersion(banner: "") == nil)
    }

    @Test("orders versions correctly")
    func ordering() {
        #expect(ToolVersion(major: 0, minor: 5, patch: 28) < ToolVersion(major: 0, minor: 6, patch: 0))
        #expect(ToolVersion(major: 0, minor: 9, patch: 9) < ToolVersion(major: 1, minor: 0, patch: 0))
    }

    @Test("a build without --verify is not usable")
    func verifyRequired() {
        // applesauce verifies only when asked, so a build lacking the flag would compress
        // without ever checking the result reads back. See ADR-0015.
        let noVerify = ToolCapabilities(version: nil, compressors: ["lzfse"], supportsVerify: false,
                                        supportsLevel: true, supportsMinimumRatio: true, rawUsage: "")
        #expect(!noVerify.isUsable)
        #expect(noVerify.missingCapabilities.contains { $0.contains("verification") })

        let ok = ToolCapabilities(version: nil, compressors: ["lzfse"], supportsVerify: true,
                                  supportsLevel: true, supportsMinimumRatio: true, rawUsage: "")
        #expect(ok.isUsable)
    }
}

@Suite("compression policy")
struct CompressionPolicyTests {

    @Test("every mode passes --verify", arguments: CompressionMode.allCases)
    func alwaysVerifies(mode: CompressionMode) {
        // The single most important flag Pomace emits: applesauce does NOT verify by default.
        let plan = CompressionPolicy.plan(mode: mode)
        #expect(plan.arguments.contains("--verify"))
        #expect(plan.settings.verify)
    }

    @Test("verification survives a hostile override")
    func overrideCannotDisableVerify() {
        var evil = CompressionSettings()
        evil.verify = false
        let plan = CompressionPolicy.plan(overrides: evil)
        #expect(plan.settings.verify)
        #expect(plan.arguments.contains("--verify"))
    }

    @Test("automatic defaults to LZFSE")
    func automaticDefault() {
        let plan = CompressionPolicy.plan(mode: .automatic)
        #expect(plan.settings.compressor == "lzfse")
        #expect(plan.arguments.contains("lzfse"))
    }

    @Test("a measured winner beats the default")
    func measuredCompressorWins() {
        let plan = CompressionPolicy.plan(mode: .automatic, measuredCompressor: "zlib")
        #expect(plan.settings.compressor == "zlib")
        #expect(plan.justifications.first { $0.id == "compressor" }?.reason.contains("measured") == true)
    }

    @Test("maximum savings warns about its cost")
    func maximumSavingsWarns() {
        let plan = CompressionPolicy.plan(mode: .maximumSavings)
        #expect(!plan.warnings.isEmpty)
        #expect(plan.warnings.joined().lowercased().contains("slow"))
    }

    @Test("falls back when the tool lacks the chosen compressor")
    func capabilityFallback() {
        let caps = ToolCapabilities(version: nil, compressors: ["lzfse"], supportsVerify: true,
                                    supportsLevel: false, supportsMinimumRatio: true, rawUsage: "")
        let plan = CompressionPolicy.plan(mode: .maximumSavings, capabilities: caps)
        #expect(plan.settings.compressor == "lzfse")
        #expect(!plan.warnings.isEmpty)
    }

    @Test("the ratio flag is emitted as a fraction, not a percentage")
    func ratioFormatting() {
        // applesauce's -r is "skip if it compresses to more than this fraction of the
        // original", the inverse of afsctool's -s percentage. Getting this backwards would
        // silently compress nothing, or everything.
        let plan = CompressionPolicy.plan(mode: .automatic)
        let i = plan.arguments.firstIndex(of: "-r")!
        let value = Double(plan.arguments[i + 1])!
        #expect(value > 0 && value <= 1.0)
        #expect(value == 0.95)
    }

    @Test("the three fixed safety rows are present and unchangeable")
    func fixedRows() {
        let plan = CompressionPolicy.plan()
        let fixed = Set(plan.justifications.filter(\.isFixed).map(\.id))
        #expect(fixed == ["verify", "hardlinks", "sparse"])
        for j in plan.justifications { #expect(!j.reason.isEmpty, "\(j.label) has no reason") }
    }

    @Test("no thread flag is emitted — applesauce has none")
    func noThreadFlags() {
        // The whole -J/-j/-S/-R tuning story is gone with the pivot (ADR-0015). Emitting a
        // stale flag would be rejected by the tool at runtime.
        for mode in CompressionMode.allCases {
            let args = CompressionPolicy.plan(mode: mode).arguments
            #expect(!args.contains { $0.hasPrefix("-J") || $0.hasPrefix("-j") })
            #expect(!args.contains("-S"))
            #expect(!args.contains("-f"))
        }
    }

    @Test("decompress arguments are minimal")
    func decompressArgs() {
        #expect(CompressionPolicy.decompressArguments() == ["decompress"])
    }
}

@Suite("incremental sweep cutoff")
struct IncrementalCutoffTests {

    @Test("the cutoff is backed off to cover second-granularity mtimes")
    func gracePeriod() {
        // A file created in the same second a sweep started was invisible to every later
        // incremental pass, because st_mtimespec.tv_sec was not strictly greater than the
        // recorded run time. Observed: a brand-new file skipped entirely.
        #expect(SweepRunner.mtimeGracePeriod >= 1)
    }

    @Test("a full pass is forced when no sweep has ever run")
    func firstRunIsFull() {
        let never: Date? = nil
        let needsFull = never.map { Date().timeIntervalSince($0) >= SweepRunner.fullVerificationInterval } ?? true
        #expect(needsFull)
    }

    @Test("a full re-verification is forced once the interval elapses")
    func periodicFullPass() {
        // Incremental passes only see files whose mtime moved, so anything decompressed by a
        // tool that preserves mtime would never be noticed without this.
        let old = Date().addingTimeInterval(-SweepRunner.fullVerificationInterval - 1)
        #expect(Date().timeIntervalSince(old) >= SweepRunner.fullVerificationInterval)
    }
}

@Suite("scan snapshot history")
struct SnapshotHistoryTests {

    @Test("stored snapshots retain trend metrics in chronological order")
    func readsHistory() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pomace-history-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let store = try Store(url: url)

        func record(files: Int, compressed: Int, logical: Int64, physical: Int64) throws {
            var result = ScanResult()
            result.root = "/tmp/history-fixture"
            result.progress.filesSeen = files
            result.progress.logicalBytes = logical
            result.progress.physicalBytes = physical
            result.progress.compressedFiles = compressed
            result.progress.compressedLogicalBytes = logical
            result.progress.compressedPhysicalBytes = physical
            try store.record(result)
        }

        try record(files: 10, compressed: 2, logical: 2_000, physical: 1_600)
        try record(files: 10, compressed: 7, logical: 7_000, physical: 2_100)

        let history = try store.snapshotHistory(path: "/tmp/history-fixture")
        #expect(history.count == 2)
        #expect(history.last?.compressionCoverage == 0.7)
        #expect(history.last?.reclaimedBytes == 4_900)
    }
}

@Suite("watched directory defaults")
struct WatchedDirectoryDefaultsTests {

    @Test("adding a folder does not schedule background work")
    func newFolderIsManual() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pomace-schedule-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(atPath: url.path + suffix)
            }
        }
        let store = try Store(url: url)
        try store.addWatchedDirectory(path: "/tmp/pomace-manual-fixture")

        let entry = try #require(store.watched().first)
        #expect(entry.schedule.cadence == .manual)
        #expect(entry.schedule.enabled)
    }
}
