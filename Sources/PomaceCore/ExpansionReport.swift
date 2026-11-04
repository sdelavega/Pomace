import Foundation

/// How much compression a folder has been losing between saved scans.
///
/// Writing to a compressed file makes macOS store it uncompressed again. Folders whose
/// files are rewritten constantly (build output, caches, mail stores) lose their savings
/// almost as fast as a sweep restores them, and sweeping them only adds I/O. This report
/// makes that visible and says when a manual schedule is the better fit.
///
/// It reasons only from scan snapshots, so it is an estimate:
/// - Deleted files also lower the reclaimed total. A drop in compressed files is only
///   counted as re-expansion beyond the drop in the folder's total file count.
/// - A user's Decompress is not re-expansion. Intervals containing one are skipped.
/// - A sweep that ran between two scans hides what it re-compressed, so a scheduled
///   folder's churn is understated rather than overstated.
public struct ExpansionReport: Sendable, Equatable {
    /// Compressed files that became uncompressed without being deleted.
    public var reExpandedFiles = 0
    /// Space those files took back, attributed proportionally from the reclaimed drop.
    public var reExpandedBytes: Int64 = 0
    /// Consecutive snapshot pairs compared.
    public var intervalsCompared = 0
    /// Pairs in which a meaningful amount of compression was lost.
    public var expandingIntervals = 0
    /// The most space the folder had reclaimed at any point in the window.
    public var peakReclaimedBytes: Int64 = 0
    /// When the analysed window starts.
    public var since: Date?

    public init() {}

    /// Snapshots are compared within the most recent `window` scans.
    public static let window = 12
    /// An interval counts as expanding once it loses this much of the reclaimed space
    /// and at least `minimumBytes`, which keeps rounding noise and tiny files out.
    public static let minimumFraction = 0.05
    public static let minimumBytes: Int64 = 1_000_000
    /// Suggest a manual schedule once at least this many intervals expanded and the total
    /// lost reaches `suggestionFraction` of the peak reclaimed space.
    public static let suggestionIntervals = 3
    public static let suggestionFraction = 0.25

    /// Whether this folder keeps undoing its own compression.
    public var suggestsManualSchedule: Bool {
        expandingIntervals >= Self.suggestionIntervals && peakReclaimedBytes > 0
            && Double(reExpandedBytes) >= Self.suggestionFraction * Double(peakReclaimedBytes)
    }

    /// - Parameters:
    ///   - history: snapshots oldest first, as `Store.snapshotHistory` returns them.
    ///   - decompressions: when the user ran Decompress on this folder.
    public static func analyze(_ history: [Store.SnapshotSummary],
                               decompressions: [Date] = []) -> ExpansionReport {
        var report = ExpansionReport()
        let recent = Array(history.suffix(window))
        report.since = recent.first?.scannedAt
        report.peakReclaimedBytes = recent.map(\.reclaimedBytes).max() ?? 0
        guard recent.count >= 2 else { return report }

        for (before, after) in zip(recent, recent.dropFirst()) {
            report.intervalsCompared += 1
            // The user's own Decompress explains any drop in this interval.
            if decompressions.contains(where: { $0 > before.scannedAt && $0 <= after.scannedAt }) {
                continue
            }
            let compressedDrop = before.compressedFiles - after.compressedFiles
            let reclaimedDrop = before.reclaimedBytes - after.reclaimedBytes
            guard compressedDrop > 0, reclaimedDrop > 0 else { continue }
            let deleted = max(0, before.files - after.files)
            let files = max(0, compressedDrop - deleted)
            guard files > 0 else { continue }
            let bytes = Int64((Double(reclaimedDrop) * Double(files) / Double(compressedDrop)).rounded())
            report.reExpandedFiles += files
            report.reExpandedBytes += bytes
            if bytes >= minimumBytes, Double(bytes) >= minimumFraction * Double(before.reclaimedBytes) {
                report.expandingIntervals += 1
            }
        }
        return report
    }
}
