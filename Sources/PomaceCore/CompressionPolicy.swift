import Foundation
import IOKit.ps

/// What the machine looks like right now. Read at the moment a run starts, not cached.
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

    /// External or rotational media. Conservative: only claims "slow" when it can tell.
    /// The clamp-to-2 rule this feeds is still unmeasured — see DEFAULTS.md §6.
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
    public var compressor = "LZFSE"
    public var zlibLevel: Int? = nil
    public var threadCount = 4
    public var concurrentIO = true          // -J when true, -j when false
    public var sortBySize = true            // -S
    public var minSavingsPercent = 5        // -s
    public var detectHardLinks = true       // -f
    public var backup = false               // -b
    public init() {}
}

/// One row of the Settings → Advanced pane: the value, why it was chosen, and whether the
/// user has overridden it.
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

    /// Flags Pomace will never emit, at any tier. `-n` disables afsctool's post-compression
    /// verification; `-L` is flagged "not recommended" by afsctool's own help. These are
    /// safety properties, not preferences. See SAFETY.md §4.
    public static let forbiddenFlags: Set<String> = ["-n", "-L"]

    public static func plan(mode: CompressionMode = .automatic,
                            profile: SystemProfile = .current(),
                            conditions: RuntimeConditions = RuntimeConditions(),
                            foreground: Bool = true,
                            measuredCompressor: String? = nil,
                            overrides: CompressionSettings? = nil,
                            capabilities: AfsctoolCapabilities? = nil) -> CompressionPlan {

        var s = CompressionSettings()
        var j: [Justification] = []
        var warnings: [String] = []

        // ---- compressor ----
        switch mode {
        case .automatic:
            if let m = measuredCompressor {
                s.compressor = m
                j.append(.init(id: "compressor", label: "Compressor", value: m,
                               reason: "measured fastest on this folder"))
            } else {
                s.compressor = "LZFSE"
                j.append(.init(id: "compressor", label: "Compressor", value: "LZFSE",
                               reason: "default — reads 33% faster than ZLIB for a similar ratio"))
            }
        case .maximumSavings:
            s.compressor = "ZLIB"; s.zlibLevel = 9
            j.append(.init(id: "compressor", label: "Compressor", value: "ZLIB level 9",
                           reason: "you asked for maximum savings — about 0.6% better than LZFSE, and roughly 6x slower"))
            warnings.append("ZLIB level 9 takes around six times as long as the default for about half a percent more space. It also reads back more slowly, every time.")
        case .fastest:
            s.compressor = "LZVN"
            j.append(.init(id: "compressor", label: "Compressor", value: "LZVN",
                           reason: "you asked for speed — the quickest compressor available"))
        }

        if let caps = capabilities, !caps.compressors.contains(s.compressor) {
            let fallback = caps.compressors.contains("LZFSE") ? "LZFSE" : (caps.compressors.first ?? "ZLIB")
            warnings.append("This copy of afsctool doesn't support \(s.compressor); using \(fallback) instead.")
            s.compressor = fallback
        }
        if s.compressor != "ZLIB" { s.zlibLevel = nil }

        // ---- threads ----
        s.threadCount = profile.threadCount(foreground: foreground,
                                            constrained: conditions.isConstrained,
                                            slowMedia: conditions.slowMedia)
        // The reason must describe the number actually chosen. An earlier version always
        // said "matched to N performance cores" even when the foreground path had picked
        // every physical core — a justification that contradicted its own value.
        var threadReason: String
        if conditions.slowMedia {
            threadReason = "external drive — extra threads only contend for the disk"
        } else if let c = conditions.constraintDescription {
            threadReason = "reduced because \(c)"
        } else if foreground {
            threadReason = profile.isAppleSilicon
                ? "all \(profile.physicalCores) cores, since you're waiting on this"
                : "all \(profile.physicalCores) cores, since you're waiting on this"
        } else {
            threadReason = profile.isAppleSilicon
                ? "matched to \(profile.performanceCores) performance cores, leaving the efficiency cores for your other work"
                : "matched to \(profile.physicalCores) cores"
        }
        j.append(.init(id: "threads", label: "Threads", value: "\(s.threadCount)", reason: threadReason))

        // ---- I/O concurrency ----
        s.concurrentIO = !conditions.slowMedia
        j.append(.init(id: "io", label: "Disk access",
                       value: s.concurrentIO ? "Concurrent" : "One file at a time",
                       reason: s.concurrentIO
                           ? "26% faster on an internal SSD"
                           : "safer on external media, which handles parallel writes poorly"))

        // ---- fixed safety properties ----
        s.sortBySize = true
        j.append(.init(id: "sort", label: "Order", value: "Smallest first",
                       reason: "leaves the largest files last, so running low on space can't strand a part-finished run",
                       isFixed: true))
        s.detectHardLinks = true
        j.append(.init(id: "hardlinks", label: "Hard links", value: "Detected",
                       reason: "compressing one path affects every file sharing its data",
                       isFixed: true))
        j.append(.init(id: "verify", label: "Verification", value: "Always on",
                       reason: "afsctool re-reads every file after compressing it; Pomace never turns this off",
                       isFixed: true))

        // ---- threshold ----
        s.minSavingsPercent = mode == .maximumSavings ? 1 : 5
        j.append(.init(id: "threshold", label: "Minimum saving", value: "\(s.minSavingsPercent)%",
                       reason: "files that would gain less than this are left alone"))

        // ---- overrides ----
        if let o = overrides {
            let auto = s
            s = o
            j = j.map { row in
                var r = row
                switch row.id {
                case "compressor": r.isOverridden = o.compressor != auto.compressor
                                   r.value = o.compressor + (o.zlibLevel.map { " level \($0)" } ?? "")
                case "threads":    r.isOverridden = o.threadCount != auto.threadCount
                                   r.value = "\(o.threadCount)"
                case "threshold":  r.isOverridden = o.minSavingsPercent != auto.minSavingsPercent
                                   r.value = "\(o.minSavingsPercent)%"
                case "io":         r.isOverridden = o.concurrentIO != auto.concurrentIO
                                   r.value = o.concurrentIO ? "Concurrent" : "One file at a time"
                default: break
                }
                if r.isOverridden { r.reason = "set by you" }
                return r
            }
            // Safety properties survive any override.
            s.sortBySize = true
            s.detectHardLinks = true
        }

        return CompressionPlan(settings: s, justifications: j,
                               arguments: arguments(for: s), warnings: warnings)
    }

    /// Builds the argv. `-v` is always present because the progress UI parses its output;
    /// the forbidden flags are never emitted, and a test asserts it.
    public static func arguments(for s: CompressionSettings) -> [String] {
        var a = ["-c", "-v"]
        a += ["-T", s.compressor]
        if s.compressor == "ZLIB", let level = s.zlibLevel { a.append("-\(level)") }
        a.append("\(s.concurrentIO ? "-J" : "-j")\(s.threadCount)")
        if s.sortBySize { a.append("-S") }
        if s.detectHardLinks { a.append("-f") }
        if s.minSavingsPercent > 0 { a += ["-s", "\(s.minSavingsPercent)"] }
        if s.backup { a.append("-b") }
        return a
    }

    public static func decompressArguments() -> [String] { ["-d", "-v"] }
}
