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
