import Foundation

/// Where afsctool came from. Shown to the user, because "which binary is this actually
/// running?" is a question they deserve an answer to before it touches their files.
public enum AfsctoolSource: Sendable, Equatable {
    case userConfigured(String)
    case homebrew(String)
    case privateCopy(String)
    case searchPath(String)

    public var path: String {
        switch self {
        case .userConfigured(let p), .homebrew(let p), .privateCopy(let p), .searchPath(let p): p
        }
    }

    public var description: String {
        switch self {
        case .userConfigured: "a location you chose"
        case .homebrew: "Homebrew"
        case .privateCopy: "Pomace's own copy"
        case .searchPath: "your PATH"
        }
    }
}

public struct AfsctoolVersion: Sendable, Comparable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public var description: String { "\(major).\(minor).\(patch)" }

    public init(major: Int, minor: Int, patch: Int) {
        (self.major, self.minor, self.patch) = (major, minor, patch)
    }

    /// Parses the leading "afsctool 1.7.2." banner. Tolerates a trailing period and extra text.
    public init?(banner: String) {
        guard let line = banner.split(separator: "\n").first else { return nil }
        let digits = line.drop { !$0.isNumber }
        let parts = digits.prefix { $0.isNumber || $0 == "." }
            .split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        major = parts[0]; minor = parts[1]; patch = parts.count > 2 ? parts[2] : 0
    }

    public static func < (a: Self, b: Self) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }
}

public struct AfsctoolCapabilities: Sendable {
    public let version: AfsctoolVersion?
    public let compressors: Set<String>
    public let supportsThreads: Bool
    public let supportsSort: Bool
    public let supportsMinSavings: Bool
    public let supportsHardLinkDetection: Bool
    public let supportsBackup: Bool
    public let rawUsage: String

    /// The flags Pomace actually intends to pass. If any is missing we degrade rather than
    /// discovering it mid-run against the user's files.
    public var isUsable: Bool {
        compressors.contains("LZFSE") && supportsThreads && supportsHardLinkDetection
    }

    public var missingCapabilities: [String] {
        var out: [String] = []
        if !compressors.contains("LZFSE") { out.append("LZFSE compression") }
        if !supportsThreads { out.append("multi-threading (-J)") }
        if !supportsHardLinkDetection { out.append("hard-link detection (-f)") }
        if !supportsSort { out.append("size sorting (-S)") }
        if !supportsMinSavings { out.append("minimum-savings threshold (-s)") }
        return out
    }
}

public struct AfsctoolInstallation: Sendable {
    public let source: AfsctoolSource
    public let capabilities: AfsctoolCapabilities
    public var path: String { source.path }
}

public enum AfsctoolLocator {

    public static var privateBinaryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomace/bin/afsctool")
    }

    static let wellKnownPaths = ["/opt/homebrew/bin/afsctool", "/usr/local/bin/afsctool"]

    /// Resolution order per PRD §5.5. First hit that is actually executable wins.
    public static func locate(userConfigured: String? = nil) -> AfsctoolSource? {
        let fm = FileManager.default
        if let p = userConfigured, fm.isExecutableFile(atPath: p) { return .userConfigured(p) }
        for p in wellKnownPaths where fm.isExecutableFile(atPath: p) { return .homebrew(p) }
        let priv = privateBinaryURL.path
        if fm.isExecutableFile(atPath: priv) { return .privateCopy(priv) }
        if let p = searchPath(), fm.isExecutableFile(atPath: p) { return .searchPath(p) }
        return nil
    }

    static func searchPath() -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/afsctool"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Runs the binary and reads what it can actually do, rather than assuming from a
    /// version number. afsctool 1.7.3 self-reports "1.7.2" in its banner, so the version
    /// string alone is not trustworthy.
    public static func probe(_ source: AfsctoolSource) -> AfsctoolInstallation {
        let usage = Subprocess.capture(source.path, []).combined
        var compressors: Set<String> = []
        for name in ["ZLIB", "LZVN", "LZFSE"] where usage.contains(name) { compressors.insert(name) }
        let caps = AfsctoolCapabilities(
            version: AfsctoolVersion(banner: usage),
            compressors: compressors,
            supportsThreads: usage.contains("-jN") || usage.contains("-JN"),
            supportsSort: usage.contains("-S "),
            supportsMinSavings: usage.contains("-s <percentage>"),
            supportsHardLinkDetection: usage.contains("-f "),
            supportsBackup: usage.contains("-b "),
            rawUsage: usage)
        return AfsctoolInstallation(source: source, capabilities: caps)
    }

    public static func discover(userConfigured: String? = nil) -> AfsctoolInstallation? {
        locate(userConfigured: userConfigured).map(probe)
    }
}

/// Minimal process runner. Kept here so PomaceCore has no Foundation-Process usage scattered
/// through it and so tests can reason about one place.
public enum Subprocess {

    public struct Output: Sendable {
        public let stdout: String, stderr: String, code: Int32
        public var combined: String { stdout + stderr }
        public var succeeded: Bool { code == 0 }
    }

    public static func capture(_ launchPath: String, _ args: [String]) -> Output {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return Output(stdout: "", stderr: "\(error)", code: -1) }
        let od = o.fileHandleForReading.readDataToEndOfFile()
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Output(stdout: String(decoding: od, as: UTF8.self),
                      stderr: String(decoding: ed, as: UTF8.self),
                      code: p.terminationStatus)
    }
}
