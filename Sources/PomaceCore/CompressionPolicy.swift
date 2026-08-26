import Foundation
import IOKit.ps

/// What the machine looks like right now. Read when a run starts, never cached.
///
/// Since the pivot to applesauce these conditions no longer tune a thread count — applesauce
/// parallelises internally and exposes no thread flag. They still decide *whether* a
/// background sweep runs at all (ADR-0015).
public struct RuntimeConditions: Sendable {
    public var onBattery = false
    public var lowPowerMode = false
    public var thermalPressure = false
    public var slowMedia = false

    public init(onBattery: Bool = false, lowPowerMode: Bool = false,
                thermalPressure: Bool = false, slowMedia: Bool = false) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.thermalPressure = thermalPressure
        self.slowMedia = slowMedia
    }

    public var isConstrained: Bool { onBattery || lowPowerMode || thermalPressure }

    public var constraintDescription: String? {
        if thermalPressure { return "the Mac is running warm" }
        if lowPowerMode { return "Low Power Mode is on" }
        if onBattery { return "running on battery" }
        return nil
    }

    public static func current(volumePath: String? = nil) -> RuntimeConditions {
        var c = RuntimeConditions()
        c.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let thermal = ProcessInfo.processInfo.thermalState
        c.thermalPressure = thermal == .serious || thermal == .critical
        c.onBattery = !isOnACPower()
        if let path = volumePath { c.slowMedia = isSlowMedia(path) }
        return c
    }

    static func isOnACPower() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return true }
        guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String?
        else { return true }
        return type == kIOPSACPowerValue
    }

    static func isSlowMedia(_ path: String) -> Bool {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return false }
        let mount = withUnsafeBytes(of: fs.f_mntonname) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return mount.hasPrefix("/Volumes/")
    }
}

public struct CompressionSettings: Sendable, Equatable {
    public var compressor = "lzfse"
    /// Skip a file if it would compress to more than this fraction of its original size.
    /// applesauce's `-r`; 0.95 is its own default.
    public var minimumRatio = 0.95
    /// Always true. See `CompressionPolicy.verifyIsMandatory`.
    public var verify = true
    public init() {}
}

public struct Justification: Sendable, Identifiable, Equatable {
    public let id: String
    public let label: String
    public var value: String
    public var reason: String
    public var isOverridden = false
    /// Safety properties the user cannot change at any tier — see SAFETY.md §4.
    public var isFixed = false

    public init(id: String, label: String, value: String, reason: String,
                isOverridden: Bool = false, isFixed: Bool = false) {
        self.id = id; self.label = label; self.value = value
        self.reason = reason; self.isOverridden = isOverridden; self.isFixed = isFixed
    }
}

public struct CompressionPlan: Sendable {
    public let settings: CompressionSettings
    public let justifications: [Justification]
    public let arguments: [String]
    public let warnings: [String]
}

public enum CompressionMode: String, Sendable, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case maximumSavings = "Maximum savings"
    case fastest = "Fastest"
    public var id: String { rawValue }

    public var explanation: String {
        switch self {
        case .automatic: "Pomace measures this folder and picks what works best for it"
        case .maximumSavings: "Reclaims the most space, and takes noticeably longer"
        case .fastest: "Finishes soonest, reclaiming a little less"
        }
    }
}

public enum CompressionPolicy {

    /// applesauce verifies only when asked — the inverse of afsctool, where verification was
    /// on unless you passed `-n`. Every compress invocation carries `--verify`, and a test
    /// asserts it. This is the single most important flag Pomace passes.
    public static let verifyIsMandatory = true

    /// applesauce exposes no thread flag; it parallelises at block level internally. The
    /// whole `-J`/`-j`/`-S`/`-R` tuning story from the afsctool era is simply gone, along
    /// with the hard-link thread-count hazard that made it dangerous (ADR-0015).
    public static func plan(mode: CompressionMode = .automatic,
                            conditions: RuntimeConditions = RuntimeConditions(),
                            measuredCompressor: String? = nil,
                            overrides: CompressionSettings? = nil,
                            capabilities: ToolCapabilities? = nil) -> CompressionPlan {

        var s = CompressionSettings()
        var j: [Justification] = []
        var warnings: [String] = []

        switch mode {
        case .automatic:
            if let m = measuredCompressor {
                s.compressor = m
                j.append(.init(id: "compressor", label: "Compressor", value: m.uppercased(),
                               reason: "measured best on this folder"))
            } else {
                s.compressor = "lzfse"
                j.append(.init(id: "compressor", label: "Compressor", value: "LZFSE",
                               reason: "default — reads back fastest, for a ratio within a point of the alternatives"))
            }
        case .maximumSavings:
            s.compressor = "zlib"
            s.minimumRatio = 0.99
            j.append(.init(id: "compressor", label: "Compressor", value: "ZLIB",
                           reason: "you asked for maximum savings — a slightly better ratio, and slower to read back"))
            warnings.append("ZLIB reclaims marginally more space than the default, but every later read of these files is slower. Measured on a mixed corpus the difference in size was under one percent.")
        case .fastest:
            s.compressor = "lzvn"
            j.append(.init(id: "compressor", label: "Compressor", value: "LZVN",
                           reason: "you asked for speed"))
        }

        if let caps = capabilities, !caps.compressors.contains(s.compressor) {
            let fallback = caps.compressors.contains("lzfse") ? "lzfse" : (caps.compressors.sorted().first ?? "lzfse")
            warnings.append("This copy of \(CompressorTool.displayName) doesn't support \(s.compressor.uppercased()); using \(fallback.uppercased()) instead.")
            s.compressor = fallback
        }

        j.append(.init(id: "threshold", label: "Minimum saving",
                       value: "\(Int((1 - s.minimumRatio) * 100))%",
                       reason: "files that would gain less than this are left alone"))

        j.append(.init(id: "verify", label: "Verification", value: "Always on",
                       reason: "\(CompressorTool.displayName) re-reads every file and compares it before replacing the original; Pomace never turns this off",
                       isFixed: true))
        j.append(.init(id: "hardlinks", label: "Hard links", value: "Skipped",
                       reason: "\(CompressorTool.displayName) refuses files that share storage with another file, which is why Pomace lists them as excluded rather than silently doing nothing",
                       isFixed: true))
        j.append(.init(id: "sparse", label: "Sparse files", value: "Skipped",
                       reason: "compressing one would materialise its empty space and use more disk, not less",
                       isFixed: true))

        if let o = overrides {
            let auto = s
            s = o
            s.verify = true                      // never overridable
            j = j.map { row in
                var r = row
                switch row.id {
                case "compressor":
                    r.isOverridden = o.compressor != auto.compressor
                    r.value = o.compressor.uppercased()
                case "threshold":
                    r.isOverridden = o.minimumRatio != auto.minimumRatio
                    r.value = "\(Int((1 - o.minimumRatio) * 100))%"
                default: break
                }
                if r.isOverridden { r.reason = "set by you" }
                return r
            }
        }

        return CompressionPlan(settings: s, justifications: j,
                               arguments: compressArguments(for: s), warnings: warnings)
    }

    /// applesauce's compress argv. `--verify` is unconditional.
    public static func compressArguments(for s: CompressionSettings) -> [String] {
        var a = ["compress", "--verify"]
        a += ["-c", s.compressor]
        a += ["-r", String(format: "%.4f", s.minimumRatio)]
        return a
    }

    public static func decompressArguments() -> [String] { ["decompress"] }
}
