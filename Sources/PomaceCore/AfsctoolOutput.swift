import Foundation

/// Tolerant parser for `afsctool -v` output.
///
/// The format is human-oriented and version-dependent, so this NEVER fails an operation.
/// Unrecognized lines are collected for diagnosis; the compression itself is authoritative
/// and our reading of its chatter is not. See docs/ARCHITECTURE.md §4.2.
public struct AfsctoolReport: Sendable {
    public var path: String?
    public var compressionTypeRaw: UInt32?
    public var compressionTypeText: String?
    public var contentType: String?
    public var uncompressedSize: Int64?
    public var compressedSize: Int64?
    public var savingsPercent: Double?
    public var xattrCount: Int?
    /// afsctool's own xattr-payload figure — useful for cross-checking our inline-xattr math.
    public var xattrDataSize: Int64?
    public var unparsedLines: [String] = []
}

public enum AfsctoolOutput {

    public static func parse(_ text: String) -> AfsctoolReport {
        var r = AfsctoolReport()
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasSuffix(":"), line.contains("/") {
                r.path = String(line.dropLast()); continue
            }
            // "Compression type: ZLIB in resource fork (4)"
            if let v = value(line, "Compression type") {
                r.compressionTypeText = v
                if let open = v.lastIndex(of: "("), let close = v.lastIndex(of: ")"), open < close {
                    r.compressionTypeRaw = UInt32(v[v.index(after: open)..<close])
                }
                continue
            }
            if let v = value(line, "File content type") { r.contentType = v; continue }
            if let v = value(line, "Number of extended attributes") { r.xattrCount = Int(v); continue }
            if line.hasPrefix("Total size of extended attribute data"), let b = leadingBytes(after: line) {
                r.xattrDataSize = b; continue
            }
            // "Compression savings: 99.4%"
            if let v = value(line, "Compression savings") {
                r.savingsPercent = Double(v.replacingOccurrences(of: "%", with: "")); continue
            }
            // "File size (compressed): 12288 bytes / 12 KiB"
            if line.hasPrefix("File size (compressed)"), let b = leadingBytes(after: line) {
                r.compressedSize = b; continue
            }
            if line.hasPrefix("File size (uncompressed"), let b = leadingBytes(after: line) {
                r.uncompressedSize = b; continue
            }
            if let v = value(line, "Uncompressed file size reported in compressed header"),
               let b = Int64(v.split(separator: " ").first.map(String.init) ?? "") {
                r.uncompressedSize = r.uncompressedSize ?? b; continue
            }
            r.unparsedLines.append(line)
        }
        return r
    }

    private static func value(_ line: String, _ key: String) -> String? {
        guard line.hasPrefix(key), let c = line.firstIndex(of: ":") else { return nil }
        return String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
    }

    /// Pulls the byte count out of "…: 12288 bytes / 12 KiB".
    private static func leadingBytes(after line: String) -> Int64? {
        guard let c = line.firstIndex(of: ":") else { return nil }
        let rest = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        return Int64(rest.split(separator: " ").first.map(String.init) ?? "")
    }
}
