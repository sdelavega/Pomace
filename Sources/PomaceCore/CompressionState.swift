import Foundation

/// decmpfs compression types, as stored in the `com.apple.decmpfs` header.
public enum CompressionType: UInt32, Sendable, CaseIterable {
    case storedInline = 1
    case zlibXattr    = 3
    case zlibResource = 4
    case lzvnXattr    = 7
    case lzvnResource = 8
    case lzfseXattr   = 11
    case lzfseResource = 12

    public var algorithm: String {
        switch self {
        case .storedInline: "none"
        case .zlibXattr, .zlibResource: "ZLIB"
        case .lzvnXattr, .lzvnResource: "LZVN"
        case .lzfseXattr, .lzfseResource: "LZFSE"
        }
    }

    /// Where the compressed payload lives. This determines how physical size is computed —
    /// see `FileInspector`. Getting it wrong silently over-reports savings.
    public var storage: Storage {
        switch self {
        case .storedInline, .zlibXattr, .lzvnXattr, .lzfseXattr: .inlineXattr
        case .zlibResource, .lzvnResource, .lzfseResource: .resourceFork
        }
    }

    public enum Storage: Sendable { case inlineXattr, resourceFork }

    public var description: String { "\(algorithm) / \(storage == .inlineXattr ? "xattr" : "rsrc")" }
}

/// The `com.apple.decmpfs` header: 4-byte 'fpmc' magic, LE uint32 type, LE uint64 size.
public struct DecmpfsHeader: Sendable {
    public static let magic: UInt32 = 0x636d7066   // 'fpmc' little-endian
    public static let length = 16

    public let rawType: UInt32
    public let uncompressedSize: UInt64
    public var type: CompressionType? { CompressionType(rawValue: rawType) }

    public init?(_ bytes: [UInt8]) {
        guard bytes.count >= Self.length else { return nil }
        func le32(_ o: Int) -> UInt32 { bytes[o..<o+4].reversed().reduce(0) { $0 << 8 | UInt32($1) } }
        func le64(_ o: Int) -> UInt64 { bytes[o..<o+8].reversed().reduce(0) { $0 << 8 | UInt64($1) } }
        guard le32(0) == Self.magic else { return nil }
        rawType = le32(4)
        uncompressedSize = le64(8)
    }
}
