import Foundation

/// Why a file or directory must not be compressed, or should be flagged first.
/// Every case here is grounded in docs/SAFETY.md; several were promoted from suspicion to
/// certainty by the M0 spike.
public enum SafetyReason: Sendable, Equatable {
    // Hard exclusions — never compressed, not user-overridable.
    case systemPath
    case sparseFile(allocatedBytes: Int64, logicalBytes: Int64)
    case existingResourceFork
    case liveDatabase(String)
    case virtualMachineImage
    case cloudSyncedDirectory(String)
    case timeMachineVolume
    case unsupportedFilesystem(String)
    case networkVolume
    case zeroLength
    case notRegularFile

    // Advisory — allowed, but the user is told first.
    case applicationBundle
    case hardLinked(linkCount: Int)
    case veryLargeFile(bytes: Int64)
    case likelyIncompressible(String)

    public var isHardExclusion: Bool {
        switch self {
        case .applicationBundle, .hardLinked, .veryLargeFile, .likelyIncompressible: false
        default: true
        }
    }

    /// Shown directly in the UI beside the excluded file, so it must read as a sentence.
    public var explanation: String {
        switch self {
        case .systemPath:
            "On the sealed system volume, which is read-only"
        case .sparseFile(let a, let l):
            "Sparse file — occupies \(ByteFormat.short(a)) of \(ByteFormat.short(l)). "
            + "Compressing it would materialize the empty space and use more disk, not less"
        case .existingResourceFork:
            "Already has a resource fork, which is where the compressed data would need to go"
        case .liveDatabase(let kind):
            "\(kind) is written to constantly; compression would be undone immediately"
        case .virtualMachineImage:
            "Virtual machine images are written in place and can use low-level disk access"
        case .cloudSyncedDirectory(let service):
            "Inside \(service) — modifying every file could trigger a full re-upload"
        case .timeMachineVolume:
            "Time Machine backup storage"
        case .unsupportedFilesystem(let fs):
            "\(fs.uppercased()) volumes don't support transparent compression"
        case .networkVolume:
            "Network volumes don't support transparent compression"
        case .zeroLength:
            "Empty file — nothing to compress"
        case .notRegularFile:
            "Not a regular file"
        case .applicationBundle:
            "Application bundle — generally safe, and signatures still validate, "
            + "but worth verifying the app afterwards"
        case .hardLinked(let n):
            "Shares its data with \(n - 1) other file\(n == 2 ? "" : "s"); compressing affects all of them"
        case .veryLargeFile(let b):
            "\(ByteFormat.short(b)) — this one file will take a while and can't be interrupted partway"
        case .likelyIncompressible(let kind):
            "\(kind) is already compressed; there's little or nothing to reclaim"
        }
    }
}

public enum ByteFormat {
    public static func short(_ b: Int64) -> String {
        let u = ["bytes", "KB", "MB", "GB", "TB"]
        var v = Double(b), i = 0
        while v >= 1000, i < u.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? "\(b) bytes" : String(format: "%.1f %@", v, u[i])
    }
}

public struct SafetyRules: Sendable {

    public init() {}

    static let systemPrefixes = ["/System", "/bin", "/sbin", "/private/var/db"]
    static let usrExempt = "/usr/local"

    static let cloudMarkers: [(String, String)] = [
        ("/Library/Mobile Documents", "iCloud Drive"),
        ("/Dropbox", "Dropbox"),
        ("/Google Drive", "Google Drive"),
        ("/My Drive", "Google Drive"),
        ("/OneDrive", "OneDrive"),
        ("/Library/CloudStorage", "cloud storage"),
    ]

    static let vmExtensions: Set<String> = [
        "vmdk", "qcow2", "utm", "pvm", "vbox", "vdi", "hds", "vmwarevm", "sparsebundle", "dmg",
    ]

    static let incompressible: [String: String] = [
        "jpg": "JPEG", "jpeg": "JPEG", "png": "PNG", "heic": "HEIC", "gif": "GIF", "webp": "WebP",
        "mp4": "H.264 video", "mov": "QuickTime video", "m4v": "video", "mkv": "video", "avi": "video",
        "mp3": "MP3 audio", "m4a": "AAC audio", "aac": "audio", "flac": "FLAC audio",
        "zip": "ZIP archive", "gz": "gzip archive", "bz2": "bzip2 archive", "xz": "xz archive",
        "7z": "7-Zip archive", "rar": "RAR archive", "zst": "zstd archive",
        "icns": "icon archive", "pdf": "PDF",
    ]

    static let databaseExtensions: [String: String] = [
        "sqlite": "SQLite database", "sqlite3": "SQLite database", "db": "Database",
        "realm": "Realm database", "sqlitedb": "SQLite database",
    ]

    /// Very large files are slow and uninterruptible mid-file (docs/SAFETY.md §3).
    public static let largeFileThreshold: Int64 = 4 * 1024 * 1024 * 1024

    // MARK: - Evaluation

    /// How much work a safety evaluation is allowed to do.
    ///
    /// `.fast` uses only facts already gathered by the walk — no extra syscalls. Scanning a
    /// million-file tree must use this; probing every file for a resource fork added a
    /// getxattr per file and made a 20s walk take minutes.
    ///
    /// `.thorough` adds the filesystem probes and is what runs immediately before mutation,
    /// per SAFETY.md rule 10 (re-evaluate at mutation time, never trust a cached scan).
    public enum Depth: Sendable { case fast, thorough }

    public func evaluate(_ f: FileFacts, volume: VolumeContext = .init(),
                         depth: Depth = .fast) -> [SafetyReason] {
        var reasons: [SafetyReason] = []

        if let v = volume.blockingReason { reasons.append(v) }
        guard f.isRegularFile else { return reasons + [.notRegularFile] }
        if f.logicalSize == 0 { return reasons + [.zeroLength] }

        let path = f.path
        if Self.systemPrefixes.contains(where: { path.hasPrefix($0) })
            || (path.hasPrefix("/usr") && !path.hasPrefix(Self.usrExempt)) {
            reasons.append(.systemPath)
        }
        for (marker, service) in Self.cloudMarkers where path.contains(marker) {
            reasons.append(.cloudSyncedDirectory(service)); break
        }
        if path.contains("/Backups.backupdb/") || path.contains("/.HFS+ Private Directory Data") {
            reasons.append(.timeMachineVolume)
        }

        let ext = (path as NSString).pathExtension.lowercased()
        if Self.vmExtensions.contains(ext) { reasons.append(.virtualMachineImage) }
        if let kind = Self.databaseExtensions[ext] {
            // The sidecar probe is two stat calls, but only for files that already look like
            // a database — rare enough to afford even on a fast pass.
            if ext == "realm" || hasLiveSidecar(path) { reasons.append(.liveDatabase(kind)) }
        }

        // Sparse: allocated blocks fall short of the logical size. Verified as a real hazard
        // in M0 — compressing one materializes the empty extents and costs disk.
        if !f.isCompressed, f.logicalSize > 4096, f.physicalSize < f.logicalSize {
            reasons.append(.sparseFile(allocatedBytes: f.physicalSize, logicalBytes: f.logicalSize))
        }
        if depth == .thorough, !f.isCompressed, hasResourceFork(path) {
            reasons.append(.existingResourceFork)
        }

        // Advisory
        if path.contains(".app/") { reasons.append(.applicationBundle) }
        if f.linkCount > 1 { reasons.append(.hardLinked(linkCount: Int(f.linkCount))) }
        if f.logicalSize >= Self.largeFileThreshold { reasons.append(.veryLargeFile(bytes: f.logicalSize)) }
        if let kind = Self.incompressible[ext] { reasons.append(.likelyIncompressible(kind)) }

        return reasons
    }

    public func isExcluded(_ f: FileFacts, volume: VolumeContext = .init(),
                           depth: Depth = .fast) -> Bool {
        evaluate(f, volume: volume, depth: depth).contains { $0.isHardExclusion }
    }

    // MARK: - Probes

    /// A SQLite file with a -wal or -shm sidecar has an open writer.
    func hasLiveSidecar(_ path: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: path + "-wal") || fm.fileExists(atPath: path + "-shm")
    }

    /// A resource fork on an *uncompressed* file blocks compression — it's where the
    /// compressed payload would otherwise live. Verified in M0: afsctool refuses these.
    func hasResourceFork(_ path: String) -> Bool {
        getxattr(path, "com.apple.ResourceFork", nil, 0, 0, XATTR_SHOWCOMPRESSION) > 0
    }
}

/// Volume-level facts that disqualify an entire tree.
public struct VolumeContext: Sendable {
    public var filesystem: String?
    public var isNetwork: Bool
    public var isReadOnly: Bool

    public init(filesystem: String? = nil, isNetwork: Bool = false, isReadOnly: Bool = false) {
        self.filesystem = filesystem
        self.isNetwork = isNetwork
        self.isReadOnly = isReadOnly
    }

    public var blockingReason: SafetyReason? {
        if isNetwork { return .networkVolume }
        if let fs = filesystem, !["apfs", "hfs"].contains(where: { fs.lowercased().contains($0) }) {
            return .unsupportedFilesystem(fs)
        }
        return nil
    }

    public static func probe(path: String) -> VolumeContext {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return VolumeContext() }
        let name = withUnsafeBytes(of: fs.f_fstypename) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        let flags = Int32(bitPattern: UInt32(fs.f_flags))
        return VolumeContext(filesystem: name,
                             isNetwork: name == "smbfs" || name == "nfs" || name == "afpfs",
                             isReadOnly: (flags & MNT_RDONLY) != 0)
    }
}
