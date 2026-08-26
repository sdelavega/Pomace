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

@Suite("afsctool output parsing")
struct AfsctoolOutputTests {

    let sample = """
    /Volumes/PomaceM0/corpus/text/doc1.txt:
    Compression type: ZLIB in resource fork (4)
    File content type: public.plain-text
    File size (uncompressed; reported size by Mac OS 10.6+ Finder): 2200000 bytes / 2.2 MB (megabytes, base-10)
    File size (compressed): 12288 bytes / 12 KiB
    Compression savings: 99.4%
    Number of extended attributes: 1
    Total size of extended attribute data: 11 bytes
    """

    @Test("extracts the fields we depend on")
    func parsesSample() {
        let r = AfsctoolOutput.parse(sample)
        #expect(r.compressionTypeRaw == 4)
        #expect(r.uncompressedSize == 2_200_000)
        #expect(r.compressedSize == 12288)
        #expect(r.savingsPercent == 99.4)
        #expect(r.contentType == "public.plain-text")
        #expect(r.xattrCount == 1)
        #expect(r.xattrDataSize == 11)
        #expect(r.unparsedLines.isEmpty)   // the known-good sample must parse completely
    }

    @Test("unknown lines are collected, never fatal")
    func toleratesUnknownLines() {
        let r = AfsctoolOutput.parse(sample + "\nSome Future Field: 42\nyet more chatter")
        #expect(r.compressionTypeRaw == 4)          // still parsed what it knows
        #expect(r.unparsedLines.count == 2)
    }

    @Test("empty output does not crash or fabricate values")
    func emptyInput() {
        let r = AfsctoolOutput.parse("")
        #expect(r.compressionTypeRaw == nil)
        #expect(r.compressedSize == nil)
    }
}

@Suite("thread policy")
struct SystemProfileTests {

    let m5 = SystemProfile(performanceCores: 4, efficiencyCores: 6,
                           physicalCores: 10, isAppleSilicon: true)

    @Test("background sweeps take the measured knee, not every core")
    func backgroundUsesPCores() {
        #expect(m5.threadCount(foreground: false) == 4)
    }

    @Test("foreground runs may use every physical core")
    func foregroundUsesAll() {
        #expect(m5.threadCount(foreground: true) == 10)
    }

    @Test("battery and thermal pressure reduce the count, down to the safe floor")
    func constrained() {
        // Was 2 until the afsctool hard-link corruption was measured; 2 is now unsafe.
        #expect(m5.threadCount(foreground: false, constrained: true)
                    == SystemProfile.minimumSafeThreads)
    }

    @Test("slow media reduces threads but not below the safe floor")
    func slowMedia() {
        #expect(m5.threadCount(foreground: true, slowMedia: true)
                    == SystemProfile.minimumSafeThreads)
    }

    @Test("never returns zero threads on a single-core machine")
    func neverZero() {
        let tiny = SystemProfile(performanceCores: 1, efficiencyCores: 0,
                                 physicalCores: 1, isAppleSilicon: false)
        #expect(tiny.threadCount(foreground: false, constrained: true) >= 1)
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

@Suite("compression policy")
struct CompressionPolicyTests {

    let m5 = SystemProfile(performanceCores: 4, efficiencyCores: 6,
                           physicalCores: 10, isAppleSilicon: true)

    @Test("never emits -n or -L, in any mode", arguments: CompressionMode.allCases)
    func forbiddenFlagsNeverEmitted(mode: CompressionMode) {
        // -n disables afsctool's verification; -L is "not recommended" by its own help.
        // These are safety properties, not preferences (SAFETY.md §4).
        let plan = CompressionPolicy.plan(mode: mode, profile: m5)
        for flag in CompressionPolicy.forbiddenFlags {
            #expect(!plan.arguments.contains(flag), "\(mode) emitted \(flag)")
        }
    }

    @Test("forbidden flags survive a hostile override")
    func overrideCannotForceForbiddenFlags() {
        var evil = CompressionSettings()
        evil.compressor = "LZFSE"
        evil.sortBySize = false          // user tries to disable a fixed safety property
        evil.detectHardLinks = false
        let plan = CompressionPolicy.plan(profile: m5, overrides: evil)
        #expect(plan.settings.sortBySize)
        #expect(plan.settings.detectHardLinks)
        #expect(plan.arguments.contains("-S"))
        #expect(plan.arguments.contains("-f"))
    }

    @Test("automatic mode defaults to LZFSE")
    func automaticDefault() {
        let plan = CompressionPolicy.plan(mode: .automatic, profile: m5)
        #expect(plan.settings.compressor == "LZFSE")
        #expect(plan.settings.zlibLevel == nil)
        #expect(plan.arguments.contains("LZFSE"))
    }

    @Test("a measured winner beats the default")
    func measuredCompressorWins() {
        let plan = CompressionPolicy.plan(mode: .automatic, profile: m5, measuredCompressor: "ZLIB")
        #expect(plan.settings.compressor == "ZLIB")
        #expect(plan.justifications.first { $0.id == "compressor" }?.reason
                    .contains("measured") == true)
    }

    @Test("level is emitted only for ZLIB")
    func levelOnlyForZLIB() {
        let zlib = CompressionPolicy.plan(mode: .maximumSavings, profile: m5)
        #expect(zlib.settings.compressor == "ZLIB")
        #expect(zlib.arguments.contains("-9"))

        let lzfse = CompressionPolicy.plan(mode: .automatic, profile: m5)
        #expect(!lzfse.arguments.contains { $0.hasPrefix("-") && Int($0.dropFirst()) != nil })
    }

    @Test("maximum savings warns about its cost")
    func maximumSavingsWarns() {
        let plan = CompressionPolicy.plan(mode: .maximumSavings, profile: m5)
        #expect(!plan.warnings.isEmpty)
        // The user opting into maximum savings must be told what it costs, in time.
        let text = plan.warnings.joined().lowercased()
        #expect(text.contains("long") || text.contains("slow"),
                "cost warning does not mention time: \(text)")
    }

    @Test("threads follow the machine and the conditions")
    func threadPolicy() {
        let bg = CompressionPolicy.plan(profile: m5, foreground: false)
        #expect(bg.arguments.contains("-J4"))

        let fg = CompressionPolicy.plan(profile: m5, foreground: true)
        #expect(fg.arguments.contains("-J10"))

        let hot = CompressionPolicy.plan(profile: m5,
                                         conditions: RuntimeConditions(thermalPressure: true),
                                         foreground: true)
        #expect(hot.arguments.contains("-J5"))

        // Exclusive IO on external media, but clamped UP to the safe floor: -j2 is a
        // thread count at which afsctool corrupts hard-linked files.
        let usb = CompressionPolicy.plan(profile: m5,
                                         conditions: RuntimeConditions(slowMedia: true))
        #expect(usb.arguments.contains("-j3"))
    }

    @Test("falls back when afsctool lacks the chosen compressor")
    func capabilityFallback() {
        let caps = AfsctoolCapabilities(version: nil, compressors: ["ZLIB"],
                                        supportsThreads: true, supportsSort: true,
                                        supportsMinSavings: true, supportsHardLinkDetection: true,
                                        supportsBackup: true, rawUsage: "")
        let plan = CompressionPolicy.plan(mode: .automatic, profile: m5, capabilities: caps)
        #expect(plan.settings.compressor == "ZLIB")
        #expect(!plan.warnings.isEmpty)
    }

    @Test("every justification explains itself")
    func justificationsPresentable() {
        let plan = CompressionPolicy.plan(profile: m5)
        #expect(plan.justifications.count >= 6)
        for j in plan.justifications {
            #expect(!j.value.isEmpty)
            #expect(!j.reason.isEmpty, "\(j.label) has no reason")
        }
        // The three fixed safety rows must be present and marked unchangeable.
        let fixed = plan.justifications.filter(\.isFixed).map(\.id)
        #expect(Set(fixed) == ["sort", "hardlinks", "verify"])
    }

    @Test("decompress arguments are minimal and safe")
    func decompressArgs() {
        let args = CompressionPolicy.decompressArguments()
        #expect(args.contains("-d"))
        for flag in CompressionPolicy.forbiddenFlags { #expect(!args.contains(flag)) }
    }
}

@Suite("afsctool version parsing")
struct AfsctoolVersionTests {

    @Test("parses the banner")
    func banner() throws {
        let v = try #require(AfsctoolVersion(banner: "afsctool 1.7.2.\nReport if file is…"))
        #expect(v.description == "1.7.2")
    }

    @Test("tolerates a two-component version")
    func twoComponent() throws {
        let v = try #require(AfsctoolVersion(banner: "afsctool 2.0"))
        #expect(v.description == "2.0.0")
    }

    @Test("returns nil on unparseable output")
    func garbage() {
        #expect(AfsctoolVersion(banner: "command not found") == nil)
        #expect(AfsctoolVersion(banner: "") == nil)
    }

    @Test("orders versions correctly")
    func ordering() {
        #expect(AfsctoolVersion(major: 1, minor: 7, patch: 2)
                < AfsctoolVersion(major: 1, minor: 7, patch: 3))
        #expect(AfsctoolVersion(major: 1, minor: 9, patch: 0)
                < AfsctoolVersion(major: 2, minor: 0, patch: 0))
    }
}

@Suite("failure messages")
struct FailureMessageTests {

    @Test("permission errors suggest a real next step")
    func permission() {
        let f = CompressionEngine.describeFailure(path: "/x/y.txt",
                                                  output: "y.txt: Permission denied")
        #expect(f.remedy.contains("permission") || f.remedy.contains("Full Disk Access"))
        #expect(!f.remedy.isEmpty)
    }

    @Test("disk-full errors say to free space")
    func diskFull() {
        let f = CompressionEngine.describeFailure(path: "/x/y.txt", output: "No space left on device")
        #expect(f.remedy.lowercased().contains("free up"))
    }

    @Test("an unrecognised error still reassures that the file is intact")
    func unknown() {
        let f = CompressionEngine.describeFailure(path: "/x/y.txt", output: "something odd happened")
        #expect(f.remedy.contains("not modified"))
    }
}

@Suite("hard-link data-loss guards")
struct HardLinkSafetyTests {

    let m5 = SystemProfile(performanceCores: 4, efficiencyCores: 6,
                           physicalCores: 10, isAppleSilicon: true)

    @Test("thread count never drops below the safe floor", arguments: [
        (true, false, false), (false, false, false), (false, true, false),
        (true, true, false), (false, false, true), (true, true, true),
    ])
    func neverBelowSafeFloor(foreground: Bool, constrained: Bool, slowMedia: Bool) {
        // afsctool destroys 100% of hard-linked files at -J1 and ~8% at -J2.
        let n = m5.threadCount(foreground: foreground, constrained: constrained, slowMedia: slowMedia)
        #expect(n >= SystemProfile.minimumSafeThreads,
                "got -J\(n) for fg=\(foreground) constrained=\(constrained) slow=\(slowMedia)")
    }

    @Test("the floor never exceeds the machine's real core count")
    func floorRespectsSmallMachines() {
        let dual = SystemProfile(performanceCores: 2, efficiencyCores: 0,
                                 physicalCores: 2, isAppleSilicon: false)
        #expect(dual.threadCount(foreground: true) <= 2)
    }

    @Test("no policy path emits a dangerous thread count", arguments: CompressionMode.allCases)
    func policyNeverEmitsUnsafeThreads(mode: CompressionMode) {
        for conditions in [
            RuntimeConditions(),
            RuntimeConditions(onBattery: true),
            RuntimeConditions(lowPowerMode: true, thermalPressure: true),
            RuntimeConditions(slowMedia: true),
            RuntimeConditions(onBattery: true, lowPowerMode: true,
                              thermalPressure: true, slowMedia: true),
        ] {
            for foreground in [true, false] {
                let plan = CompressionPolicy.plan(mode: mode, profile: m5,
                                                  conditions: conditions, foreground: foreground)
                let threadArg = plan.arguments.first { $0.hasPrefix("-J") || $0.hasPrefix("-j") }
                let n = Int(threadArg?.dropFirst(2) ?? "0") ?? 0
                #expect(n >= SystemProfile.minimumSafeThreads,
                        "\(mode) emitted \(threadArg ?? "none")")
            }
        }
    }
}
