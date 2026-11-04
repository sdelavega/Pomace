import Foundation

/// How compressed a folder was when Pomace last finished compressing it.
///
/// Recorded after a completed Compress (from the native re-scan that follows it) and after
/// every completed sweep. `eligibleLogicalBytes` is what was still uncompressed but
/// eligible at that moment — files the compressor declined because they would not shrink
/// enough. They stay eligible forever, so they are the floor degradation is measured from.
public struct CompressionBaseline: Sendable, Equatable {
    public let recordedAt: Date
    public let compressedLogicalBytes: Int64
    public let eligibleLogicalBytes: Int64

    public init(recordedAt: Date, compressedLogicalBytes: Int64, eligibleLogicalBytes: Int64) {
        self.recordedAt = recordedAt
        self.compressedLogicalBytes = compressedLogicalBytes
        self.eligibleLogicalBytes = eligibleLogicalBytes
    }
}

/// How far a folder has drifted from its last compression.
///
/// Files written after compression — new files, or compressed files that macOS stored
/// uncompressed again after a write — show up as eligible data beyond the baseline. That
/// excess is what a run or sweep could (re)compress, and `fraction` is its share of all the
/// folder's compressible data: 0 when nothing changed, 1 when every compressed file has
/// been rewritten.
///
/// Measured in logical bytes from aggregate scan totals, so it is an approximation:
/// deleting files the compressor had declined lowers the floor, and changing the folder's
/// exclusions changes what counts as eligible.
public struct Degradation: Sendable, Equatable {
    /// Logical bytes that are eligible and uncompressed beyond the baseline.
    public let recompressibleBytes: Int64
    /// `recompressibleBytes` as a share of compressed plus recompressible data, 0...1.
    public let fraction: Double
    /// When the folder was last compressed.
    public let since: Date

    /// Below these, a change is rounding noise rather than something worth a run.
    public static let significantFraction = 0.01
    public static let significantBytes: Int64 = 1_000_000

    public var isSignificant: Bool {
        fraction >= Self.significantFraction && recompressibleBytes >= Self.significantBytes
    }

    public static func measure(baseline: CompressionBaseline,
                               compressedLogicalBytes: Int64,
                               eligibleLogicalBytes: Int64) -> Degradation {
        let recompressible = max(0, eligibleLogicalBytes - baseline.eligibleLogicalBytes)
        let whole = max(0, compressedLogicalBytes) + recompressible
        let fraction = whole > 0 ? min(1, Double(recompressible) / Double(whole)) : 0
        return Degradation(recompressibleBytes: recompressible, fraction: fraction, since: baseline.recordedAt)
    }

    /// The folder's degradation as of its latest saved scan, or nil if Pomace has never
    /// finished compressing it. A scan older than the baseline predates the compression, so
    /// the folder counts as fully up to date until it is scanned again.
    public static func current(baseline: CompressionBaseline?,
                               latest: Store.SnapshotSummary?) -> Degradation? {
        guard let baseline else { return nil }
        guard let latest, latest.scannedAt >= baseline.recordedAt else {
            return Degradation(recompressibleBytes: 0, fraction: 0, since: baseline.recordedAt)
        }
        return measure(baseline: baseline, compressedLogicalBytes: latest.compressedLogicalBytes,
                       eligibleLogicalBytes: latest.eligibleLogicalBytes)
    }
}
