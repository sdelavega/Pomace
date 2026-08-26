import Foundation

// decmpfs compression types
let typeNames: [UInt32: String] = [
    1: "none (stored inline)", 3: "ZLIB / xattr",  4: "ZLIB / rsrc",
    7: "LZVN / xattr",         8: "LZVN / rsrc",  11: "LZFSE / xattr", 12: "LZFSE / rsrc",
]

func inspect(_ path: String) {
    var st = stat()
    guard lstat(path, &st) == 0 else { print("\(path): lstat failed"); return }

    let compressed = (st.st_flags & UInt32(UF_COMPRESSED)) != 0
    let logical  = Int64(st.st_size)
    let physical = Int64(st.st_blocks) * 512

    var typeStr = "—"
    if compressed {
        // NOTE: XATTR_SHOWCOMPRESSION is REQUIRED — the kernel hides decmpfs from normal getxattr
        let name = "com.apple.decmpfs"
        let sz = getxattr(path, name, nil, 0, 0, XATTR_SHOWCOMPRESSION)
        if sz >= 16 {
            var buf = [UInt8](repeating: 0, count: sz)
            if getxattr(path, name, &buf, sz, 0, XATTR_SHOWCOMPRESSION) == sz {
                let magic = String(bytes: buf[0..<4], encoding: .ascii) ?? "????"
                let t = buf[4..<8].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                typeStr = "\(typeNames[t] ?? "unknown") [magic=\(magic) type=\(t)]"
            }
        } else {
            typeStr = "decmpfs unreadable (getxattr -> \(sz), errno \(errno))"
        }
    }

    let pct = logical > 0 ? 100.0 - (Double(physical) / Double(logical) * 100.0) : 0
    print(String(format: "%-14@  UF_COMPRESSED=%@  logical=%9lld  physical=%9lld  saved=%5.1f%%  %@",
                 (path as NSString).lastPathComponent as NSString,
                 compressed ? "yes" : " no", logical, physical, pct, typeStr))
}

// Also demonstrate that plain getxattr (no flag) fails on the same file:
func plainGetxattrProbe(_ path: String) {
    let sz = getxattr(path, "com.apple.decmpfs", nil, 0, 0, 0)
    print("   plain getxattr(no XATTR_SHOWCOMPRESSION) -> \(sz), errno=\(errno) (\(String(cString: strerror(errno))))")
}

for p in CommandLine.arguments.dropFirst() { inspect(p); plainGetxattrProbe(p) }
