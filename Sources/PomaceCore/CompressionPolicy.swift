import Foundation
import IOKit.ps

public enum RuntimeConstraint: Sendable, Equatable {
    case onBattery, lowPowerMode, thermalPressure, slowMedia
}

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

    public var constraints: [RuntimeConstraint] {
        var result: [RuntimeConstraint] = []
        if thermalPressure { result.append(.thermalPressure) }
        if lowPowerMode { result.append(.lowPowerMode) }
        if onBattery { result.append(.onBattery) }
        if slowMedia { result.append(.slowMedia) }
        return result
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

public enum JustificationReason: Sendable, Equatable {
    case measuredBest, defaultLZFSE, maximumSavingsRequested, speedRequested
    case minimumSavingThreshold, verificationAlwaysOn, hardLinksRefused, sparseWouldGrow, setByUser
}

public enum JustificationValue: Sendable, Equatable {
    case compressor(String), percent(Int), alwaysOn, skipped
}

public enum PlanWarning: Sendable, Equatable {
    case zlibSlowerReads
    case compressorUnsupported(requested: String, using: String)
}

public struct Justification: Sendable, Identifiable, Equatable {
    public let id: String
    public var value: JustificationValue
    public var reason: JustificationReason
    public var isOverridden = false
    /// Safety properties the user cannot change at any tier — see SAFETY.md §4.
    public var isFixed = false

    public init(id: String, value: JustificationValue, reason: JustificationReason,
                isOverridden: Bool = false, isFixed: Bool = false) {
        self.id = id; self.value = value
        self.reason = reason; self.isOverridden = isOverridden; self.isFixed = isFixed
    }
}

public struct CompressionPlan: Sendable {
    public let settings: CompressionSettings
    public let justifications: [Justification]
    public let arguments: [String]
    public let warnings: [PlanWarning]
}

public enum CompressionMode: String, Sendable, CaseIterable, Identifiable {
    case automatic = "Automatic"
    case maximumSavings = "Maximum savings"
    case fastest = "Fastest"
    public var id: String { rawValue }
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
        var warnings: [PlanWarning] = []

        switch mode {
        case .automatic:
            if let m = measuredCompressor {
                s.compressor = m
                j.append(.init(id: "compressor", value: .compressor(m.uppercased()), reason: .measuredBest))
            } else {
                s.compressor = "lzfse"
                j.append(.init(id: "compressor", value: .compressor("LZFSE"), reason: .defaultLZFSE))
            }
        case .maximumSavings:
            s.compressor = "zlib"
            s.minimumRatio = 0.99
            j.append(.init(id: "compressor", value: .compressor("ZLIB"), reason: .maximumSavingsRequested))
            warnings.append(.zlibSlowerReads)
        case .fastest:
            s.compressor = "lzvn"
            j.append(.init(id: "compressor", value: .compressor("LZVN"), reason: .speedRequested))
        }

        if let caps = capabilities, !caps.compressors.contains(s.compressor) {
            let fallback = caps.compressors.contains("lzfse") ? "lzfse" : (caps.compressors.sorted().first ?? "lzfse")
            warnings.append(.compressorUnsupported(requested: s.compressor, using: fallback))
            s.compressor = fallback
        }

        j.append(.init(id: "threshold", value: .percent(Int((1 - s.minimumRatio) * 100)),
                       reason: .minimumSavingThreshold))
        j.append(.init(id: "verify", value: .alwaysOn, reason: .verificationAlwaysOn, isFixed: true))
        j.append(.init(id: "hardlinks", value: .skipped, reason: .hardLinksRefused, isFixed: true))
        j.append(.init(id: "sparse", value: .skipped, reason: .sparseWouldGrow, isFixed: true))

        if let o = overrides {
            let auto = s
            s = o
            s.verify = true                      // never overridable
            j = j.map { row in
                var r = row
                switch row.id {
                case "compressor":
                    r.isOverridden = o.compressor != auto.compressor
                    r.value = .compressor(o.compressor.uppercased())
                case "threshold":
                    r.isOverridden = o.minimumRatio != auto.minimumRatio
                    r.value = .percent(Int((1 - o.minimumRatio) * 100))
                default: break
                }
                if r.isOverridden { r.reason = .setByUser }
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
