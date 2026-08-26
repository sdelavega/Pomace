import Foundation

public struct WalkResult: Sendable {
    public var files = 0, directories = 0, symlinks = 0, errors = 0
    public var logicalTotal: Int64 = 0, physicalTotal: Int64 = 0, compressedFiles = 0
    public var byType: [UInt32: Int] = [:]
    /// Extra paths pointing at an inode already counted. Their bytes are deliberately
    /// excluded from the totals — see the note in `walkFTS`.
    public var hardLinkDuplicates = 0
    public init() {}
}

public enum DirectoryWalker {

    /// FTS-based walk. Preferred: fts_read hands back a populated `stat` per entry, so we
    /// avoid a second lstat syscall for every file in the tree.
    public static func walkFTS(_ root: String, inspect: Bool = true,
                               each: ((FileFacts) -> Void)? = nil) -> WalkResult {
        var r = WalkResult()
        let rootCopy = strdup(root)
        defer { free(rootCopy) }
        var argv: [UnsafeMutablePointer<CChar>?] = [rootCopy, nil]

        // FTS_PHYSICAL: don't follow symlinks. FTS_NOCHDIR: leave our cwd alone.
        // Do NOT add FTS_NOSTAT/FTS_NOSTAT_TYPE — they leave fts_statp unpopulated and
        // report regular files as FTS_NSOK, which silently walks a tree finding zero files.
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            r.errors += 1; return r
        }
        defer { fts_close(fts) }

        // Hard links mean one inode reachable by several paths. Counting each path's bytes
        // triples a 4 KB file into 12 KB of imaginary savings, so physical and logical bytes
        // are counted once per (device, inode). Verified 2026-08-26 on a three-link fixture.
        var seen = Set<UInt64>()
        func key(_ st: stat) -> UInt64 { UInt64(st.st_dev) &* 0x1_0000_0000 &+ UInt64(st.st_ino) }

        while let entP = fts_read(fts) {
            let e = entP.pointee
            switch Int32(e.fts_info) {
            case FTS_F, FTS_NSOK:
                r.files += 1
                guard inspect, let stp = e.fts_statp else { continue }
                let path = String(cString: e.fts_path)
                let f = FileInspector.inspect(path, st: stp.pointee)
                let isDuplicate = stp.pointee.st_nlink > 1 && !seen.insert(key(stp.pointee)).inserted
                if isDuplicate {
                    r.hardLinkDuplicates += 1
                } else {
                    r.logicalTotal += f.logicalSize
                    r.physicalTotal += f.physicalSize
                    if f.isCompressed {
                        r.compressedFiles += 1
                        if let t = f.rawType { r.byType[t, default: 0] += 1 }
                    }
                }
                each?(f)
            case FTS_D:   r.directories += 1
            case FTS_SL, FTS_SLNONE: r.symlinks += 1
            case FTS_DNR, FTS_ERR, FTS_NS: r.errors += 1
            default: break
            }
        }
        return r
    }

    /// FileManager comparison implementation, for the M0 performance bake-off only.
    public static func walkFileManager(_ root: String, inspect: Bool = true) -> WalkResult {
        var r = WalkResult()
        let url = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey]
        guard let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles.subtracting(.skipsHiddenFiles)]
        ) else { r.errors += 1; return r }

        for case let u as URL in en {
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { r.errors += 1; continue }
            if v.isDirectory == true { r.directories += 1; continue }
            if v.isSymbolicLink == true { r.symlinks += 1; continue }
            guard v.isRegularFile == true else { continue }
            r.files += 1
            guard inspect, let f = FileInspector.inspect(u.path) else { continue }
            r.logicalTotal += f.logicalSize
            r.physicalTotal += f.physicalSize
            if f.isCompressed {
                r.compressedFiles += 1
                if let t = f.rawType { r.byType[t, default: 0] += 1 }
            }
        }
        return r
    }
}
