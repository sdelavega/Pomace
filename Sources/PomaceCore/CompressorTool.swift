import Foundation

/// Where the compressor binary came from. Surfaced in the UI, because "which binary is
/// about to touch my files?" deserves an answer.
public enum ToolSource: Sendable, Equatable {
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

public struct ToolVersion: Sendable, Comparable, CustomStringConvertible {
    public let major: Int, minor: Int, patch: Int
    public var description: String { "\(major).\(minor).\(patch)" }

    public init(major: Int, minor: Int, patch: Int) {
        (self.major, self.minor, self.patch) = (major, minor, patch)
    }

    /// Parses "applesauce-cli 0.5.28".
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

public struct ToolCapabilities: Sendable {
    public let version: ToolVersion?
    public let compressors: Set<String>
    public let supportsVerify: Bool
    public let supportsLevel: Bool
    public let supportsMinimumRatio: Bool
    public let rawUsage: String

    public init(version: ToolVersion?, compressors: Set<String>, supportsVerify: Bool,
                supportsLevel: Bool, supportsMinimumRatio: Bool, rawUsage: String) {
        self.version = version
        self.compressors = compressors
        self.supportsVerify = supportsVerify
        self.supportsLevel = supportsLevel
        self.supportsMinimumRatio = supportsMinimumRatio
        self.rawUsage = rawUsage
    }

    /// `--verify` is required, not preferred. Unlike afsctool — where verification was on
    /// unless you passed `-n` — applesauce verifies only when asked. A build without it is
    /// not one Pomace will use.
    public var isUsable: Bool {
        compressors.contains("lzfse") && supportsVerify
    }

    public var missingCapabilities: [String] {
        var out: [String] = []
        if !compressors.contains("lzfse") { out.append("LZFSE compression") }
        if !supportsVerify { out.append("post-compression verification (--verify)") }
        if !supportsMinimumRatio { out.append("minimum compression ratio (-r)") }
        return out
    }
}

public struct ToolInstallation: Sendable {
    public let source: ToolSource
    public let capabilities: ToolCapabilities
    public var path: String { source.path }
}

/// Locates and probes `applesauce`.
///
/// See ADR-0015 for why applesauce rather than afsctool.
public enum CompressorTool {

    public static let executableName = "applesauce"
    public static let displayName = "applesauce"

    public static var privateBinaryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomace/bin/\(executableName)")
    }

    static let wellKnownPaths = [
        "/opt/homebrew/bin/\(executableName)",
        "/usr/local/bin/\(executableName)",
    ]

    public static func locate(userConfigured: String? = nil) -> ToolSource? {
        let fm = FileManager.default
        if let p = userConfigured, fm.isExecutableFile(atPath: p) { return .userConfigured(p) }
        for p in wellKnownPaths where fm.isExecutableFile(atPath: p) { return .homebrew(p) }
        let priv = privateBinaryURL.path
        if fm.isExecutableFile(atPath: priv) { return .privateCopy(priv) }
        if let p = searchPath() { return .searchPath(p) }
        return nil
    }

    static func searchPath() -> String? {
        guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(executableName)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Reads what the binary can do from its own help, rather than inferring from a version.
    public static func probe(_ source: ToolSource) -> ToolInstallation {
        let version = Subprocess.capture(source.path, ["--version"]).combined
        let help = Subprocess.capture(source.path, ["compress", "--help"]).combined
        var compressors: Set<String> = []
        for name in ["lzfse", "zlib", "lzvn"] where help.contains(name) { compressors.insert(name) }
        let caps = ToolCapabilities(
            version: ToolVersion(banner: version),
            compressors: compressors,
            supportsVerify: help.contains("--verify"),
            supportsLevel: help.contains("--level"),
            supportsMinimumRatio: help.contains("--minimum-compression-ratio"),
            rawUsage: help)
        return ToolInstallation(source: source, capabilities: caps)
    }

    public static func discover(userConfigured: String? = nil) -> ToolInstallation? {
        locate(userConfigured: userConfigured).map(probe)
    }
}

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

/// Installs applesauce on the user's behalf.
///
/// Never bundled or redistributed — it is GPL-3.0, exactly as afsctool was, so ADR-0003 is
/// unchanged by the pivot. It ships from a Homebrew *tap* rather than core, so the install
/// command names the tap explicitly.
public enum ToolInstaller {

    public static let homebrewFormula = "Dr-Emann/homebrew-tap/applesauce"

    public enum InstallResult: Sendable {
        case success(String)
        case failure(String)
    }

    static let brewPaths = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]

    public static var homebrewPath: String? {
        brewPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var homebrewAvailable: Bool { homebrewPath != nil }

    public static func installViaHomebrew() async -> InstallResult {
        guard let brew = homebrewPath else { return .failure("Homebrew isn't installed.") }
        return await withCheckedContinuation { continuation in
            Task.detached {
                let out = Subprocess.capture(brew, ["install", homebrewFormula])
                if out.succeeded || CompressorTool.locate() != nil {
                    continuation.resume(returning: .success(out.combined))
                } else {
                    let detail = out.combined
                        .split(separator: "\n")
                        .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map(String.init) ?? "Homebrew reported an error."
                    continuation.resume(returning: .failure(detail))
                }
            }
        }
    }
}
