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

    @Test("battery and thermal pressure halve the count")
    func constrained() {
        #expect(m5.threadCount(foreground: false, constrained: true) == 2)
    }

    @Test("slow media clamps to 2 regardless of cores")
    func slowMedia() {
        #expect(m5.threadCount(foreground: true, slowMedia: true) == 2)
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
