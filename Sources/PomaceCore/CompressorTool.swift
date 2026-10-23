import Foundation
import Security
import CryptoKit

/// Where the compressor binary came from. Surfaced in the UI, because "which binary is
/// about to touch my files?" deserves an answer.
public enum ToolSource: Sendable, Equatable {
    case bundled(String)
    case custom(String)

    public var path: String {
        switch self {
        case .bundled(let p), .custom(let p): p
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

public enum ToolCapability: Sendable, Equatable {
    case lzfse, verify, minimumRatio
}

public enum CustomCompressorRejection: Sendable, Equatable {
    case notFound, notExecutable, notRegularFile, relativePath
    case missingCapabilities([ToolCapability])
}

public struct CompressorResolution: Sendable {
    public let installation: ToolInstallation?
    public let customRejection: CustomCompressorRejection?
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

    public var missingCapabilities: [ToolCapability] {
        var out: [ToolCapability] = []
        if !compressors.contains("lzfse") { out.append(.lzfse) }
        if !supportsVerify { out.append(.verify) }
        if !supportsMinimumRatio { out.append(.minimumRatio) }
        return out
    }
}

public struct ToolInstallation: Sendable {
    public let source: ToolSource
    public let capabilities: ToolCapabilities
    public var path: String { source.path }
    public let sha256: String?

    public init(source: ToolSource, capabilities: ToolCapabilities) {
        self.init(source: source, capabilities: capabilities, sha256: CompressorTool.sha256(at: source.path))
    }

    init(source: ToolSource, capabilities: ToolCapabilities, sha256: String?) {
        self.source = source
        self.capabilities = capabilities
        self.sha256 = sha256
    }
}

/// Resolves and probes `applesauce`.
///
/// See ADR-0015 for why applesauce rather than afsctool.
public enum CompressorTool {

    public static func sha256(at path: String) -> String? {
        guard let stream = InputStream(fileAtPath: path) else { return nil }
        stream.open()
        defer { stream.close() }
        var hash = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { return nil }
            if count == 0 { break }
            hash.update(data: Data(buffer.prefix(count)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static let executableName = "applesauce"
    public static let displayName = "applesauce"
    public static let customPathDefaultsKey = "compressorCustomPath"

    public static var bundledURL: URL? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return nil }
        return bundle.appendingPathComponent("Contents/Helpers/\(executableName)")
    }

    public static func hasValidSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    }

    /// Reads what the binary can do from its own help, rather than inferring from a version.
    public static func probe(_ source: ToolSource) -> ToolInstallation {
        let hash = sha256(at: source.path)
        let version = Subprocess.capture(source.path, ["--version"]).combined
        let help = Subprocess.capture(source.path, ["compress", "--help"]).combined
        let stable = hash != nil && sha256(at: source.path) == hash
        var compressors: Set<String> = []
        for name in ["lzfse", "zlib", "lzvn"] where help.contains(name) { compressors.insert(name) }
        let caps = ToolCapabilities(
            version: ToolVersion(banner: version),
            compressors: compressors,
            supportsVerify: stable && help.contains("--verify"),
            supportsLevel: help.contains("--level"),
            supportsMinimumRatio: help.contains("--minimum-compression-ratio"),
            rawUsage: help)
        return ToolInstallation(source: source, capabilities: caps, sha256: stable ? hash : nil)
    }

    public static func resolve(customPath: String?, bundledURL: URL? = CompressorTool.bundledURL,
                               signatureIsValid: (URL) -> Bool = CompressorTool.hasValidSignature) -> CompressorResolution {
        let fm = FileManager.default
        var rejection: CustomCompressorRejection?
        if let customPath {
            if !customPath.hasPrefix("/") {
                rejection = .relativePath
            } else {
                let url = URL(fileURLWithPath: customPath).resolvingSymlinksInPath()
                if !fm.fileExists(atPath: url.path) {
                    rejection = .notFound
                } else if (try? fm.attributesOfItem(atPath: url.path)[.type]) as? FileAttributeType != .typeRegular {
                    rejection = .notRegularFile
                } else if !fm.isExecutableFile(atPath: url.path) {
                    rejection = .notExecutable
                } else {
                    let installation = probe(.custom(url.path))
                    if installation.capabilities.isUsable {
                        return CompressorResolution(installation: installation, customRejection: nil)
                    }
                    rejection = .missingCapabilities(installation.capabilities.missingCapabilities)
                }
            }
        }
        if let bundledURL, fm.fileExists(atPath: bundledURL.path),
           (try? fm.attributesOfItem(atPath: bundledURL.path)[.type]) as? FileAttributeType == .typeRegular,
           fm.isExecutableFile(atPath: bundledURL.path), signatureIsValid(bundledURL) {
            let installation = probe(.bundled(bundledURL.path))
            if installation.capabilities.isUsable {
                return CompressorResolution(installation: installation, customRejection: rejection)
            }
        }
        return CompressorResolution(installation: nil, customRejection: rejection)
    }
}

public enum Subprocess {

    // One reader per pipe: a child can fill stderr while keeping stdout open.
    private final class CapturedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func store(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
        func load() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

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
        let stdout = CapturedData()
        let readers = DispatchGroup()
        readers.enter()
        Thread.detachNewThread {
            stdout.store(o.fileHandleForReading.readDataToEndOfFile())
            readers.leave()
        }
        let ed = e.fileHandleForReading.readDataToEndOfFile()
        readers.wait()
        p.waitUntilExit()
        let od = stdout.load()
        return Output(stdout: String(decoding: od, as: UTF8.self),
                      stderr: String(decoding: ed, as: UTF8.self),
                      code: p.terminationStatus)
    }
}
