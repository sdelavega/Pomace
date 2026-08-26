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
    // NOTE: `threadCount` and `minimumSafeThreads` lived here until the applesauce pivot.
    // applesauce parallelises internally and exposes no thread flag, so both were removed
    // rather than left as dead code that looks load-bearing. See ADR-0015 and, for why the
    // floor existed at all, docs/M2-FINDINGS.md.

    public var justification: String {
        isAppleSilicon
            ? "matched to \(performanceCores) performance core\(performanceCores == 1 ? "" : "s")"
            : "matched to \(physicalCores) physical cores"
    }
}
