import Foundation

/// Machine facts the auto-tuning policy reads. See docs/DEFAULTS.md §2.
public struct SystemProfile: Sendable {
    public let performanceCores: Int
    public let efficiencyCores: Int
    public let physicalCores: Int
    public let isAppleSilicon: Bool

    public init(performanceCores: Int, efficiencyCores: Int, physicalCores: Int, isAppleSilicon: Bool) {
        self.performanceCores = performanceCores
        self.efficiencyCores = efficiencyCores
        self.physicalCores = physicalCores
        self.isAppleSilicon = isAppleSilicon
    }

    public static func current() -> SystemProfile {
        func sysctlInt(_ name: String) -> Int? {
            var value: Int = 0, size = MemoryLayout<Int>.size
            return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
        }
        let p = sysctlInt("hw.perflevel0.physicalcpu")
        let e = sysctlInt("hw.perflevel1.physicalcpu")
        let phys = sysctlInt("hw.physicalcpu") ?? ProcessInfo.processInfo.processorCount
        return SystemProfile(performanceCores: p ?? phys,
                             efficiencyCores: e ?? 0,
                             physicalCores: phys,
                             isAppleSilicon: p != nil)
    }

    /// Thread count for `-J`. The measured knee sits at the P-core count: near-linear
    /// scaling to that point, then a cliff (docs/DEFAULTS.md §1.2). Background sweeps take
    /// the knee and leave the E-cores for the user's actual work; a foreground run the user
    /// is watching may use every physical core.
    /// afsctool corrupts hard-linked files at low thread counts — measured at 100% loss
    /// with `-J1` and about 8% with `-J2`. The engine's one-path-per-inode rule is the
    /// actual fix; this floor is defence in depth so a single missed path cannot land in
    /// the worst case. Never lower it.
    public static let minimumSafeThreads = 3

    public func threadCount(foreground: Bool, constrained: Bool = false, slowMedia: Bool = false) -> Int {
        var n = slowMedia ? 2 : (foreground ? physicalCores : performanceCores)
        if constrained && !slowMedia { n = max(1, n / 2) }
        // Clamp up to the safe floor, but never above what the machine actually has.
        return max(1, min(max(n, Self.minimumSafeThreads), physicalCores))
    }

    public var justification: String {
        isAppleSilicon
            ? "matched to \(performanceCores) performance core\(performanceCores == 1 ? "" : "s")"
            : "matched to \(physicalCores) physical cores"
    }
}
