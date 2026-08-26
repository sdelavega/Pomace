import Foundation

public struct FileFacts: Sendable {
    public let path: String
    public let logicalSize: Int64
    public let physicalSize: Int64
    public let isCompressed: Bool
    public let type: CompressionType?
    public let rawType: UInt32?
    public let decmpfsXattrSize: Int
    public let linkCount: UInt16
    public let isRegularFile: Bool

    public var savedBytes: Int64 { max(0, logicalSize - physicalSize) }
    public var savedPercent: Double {
        logicalSize > 0 ? 100.0 - (Double(physicalSize) / Double(logicalSize) * 100.0) : 0
    }
}

public enum FileInspector {

    /// REQUIRED for every decmpfs read. The kernel hides `com.apple.decmpfs` and
    /// `com.apple.ResourceFork` from ordinary getxattr/listxattr; without this flag a
    /// compressed file returns ENOATTR and silently reads as "not compressed".
    /// Verified 2026-08-26 — see docs/ARCHITECTURE.md §3.1.
    public static let showCompression = XATTR_SHOWCOMPRESSION

    public static func inspect(_ path: String) -> FileFacts? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return inspect(path, st: st)
    }

    /// Overload taking a stat we already have — FTS hands us one for free during a walk,
    /// so this avoids a second syscall per file.
    public static func inspect(_ path: String, st: stat) -> FileFacts {
        let isReg = (st.st_mode & S_IFMT) == S_IFREG
        let compressed = (st.st_flags & UInt32(UF_COMPRESSED)) != 0
        let logical = Int64(st.st_size)
        let blockBytes = Int64(st.st_blocks) * 512

        var header: DecmpfsHeader?
        var xattrSize = 0
        if compressed {
            let probe = getxattr(path, "com.apple.decmpfs", nil, 0, 0, showCompression)
            if probe >= DecmpfsHeader.length {
                xattrSize = probe
                var buf = [UInt8](repeating: 0, count: probe)
                if getxattr(path, "com.apple.decmpfs", &buf, probe, 0, showCompression) == probe {
                    header = DecmpfsHeader(buf)
                }
            }
        }

        return FileFacts(
            path: path,
            logicalSize: logical,
            physicalSize: physicalSize(compressed: compressed, blockBytes: blockBytes,
                                       header: header, xattrSize: xattrSize),
            isCompressed: compressed,
            type: header?.type,
            rawType: header?.rawType,
            decmpfsXattrSize: xattrSize,
            linkCount: st.st_nlink,
            isRegularFile: isReg
        )
    }

    /// The rule that `st_blocks * 512` alone gets wrong.
    ///
    /// - **Resource-fork storage** (types 4/8/12): the fork is counted in `st_blocks`.
    ///   Correct as-is; agrees with afsctool exactly.
    /// - **Inline-xattr storage** (types 1/3/7/11): the compressed payload lives in the
    ///   decmpfs xattr. `st_blocks` is either 0 (small xattr living in the inode record) or
    ///   a full block (xattr spilled to its own storage). So it is `max`, **not** a sum —
    ///   summing double-counts a payload that is already inside the allocated block.
    ///
    /// Measured 2026-08-26: a 202-byte xattr on a file with `st_blocks = 8` is 4096 bytes on
    /// disk, matching afsctool — not 4298. A 48-byte xattr with `st_blocks = 0` costs 48
    /// bytes, where afsctool reports 0.
    static func physicalSize(compressed: Bool, blockBytes: Int64,
                             header: DecmpfsHeader?, xattrSize: Int) -> Int64 {
        guard compressed else { return blockBytes }
        guard let storage = header?.type?.storage else {
            // Compressed but unknown type — trust st_blocks, falling back to the xattr length
            // so we never claim a file occupies nothing at all.
            return max(blockBytes, Int64(xattrSize))
        }
        switch storage {
        case .resourceFork: return blockBytes
        case .inlineXattr:  return max(blockBytes, Int64(xattrSize))
        }
    }
}
