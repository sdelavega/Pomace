import Foundation

public struct ScanProgress: Sendable {
    public var filesSeen = 0
    public var directoriesSeen = 0
    public var logicalBytes: Int64 = 0
    public var physicalBytes: Int64 = 0
    public var compressedFiles = 0
    public var excludedFiles = 0
    public var compressedLogicalBytes: Int64 = 0
    public var compressedPhysicalBytes: Int64 = 0
    /// Counted across the WHOLE tree during the walk. Deriving this from `entries` instead
    /// silently caps it at `maxRetainedEntries` and under-reports large directories.
    public var eligibleFiles = 0
    public var eligibleLogicalBytes: Int64 = 0
    public var currentPath: String?
    public init() {}
}

public struct ScanEntry: Sendable, Identifiable {
    /// View identity must be the PATH, not the inode. Hard links share an inode, and
    /// duplicate Identifiable IDs make SwiftUI's Table render one row repeatedly — two
    /// hard-linked files both displayed as the first one's name.
    public var id: String { path }
    /// Kept for byte accounting, where collapsing by inode is exactly what we want.
    public let inode: UInt64
    public let path: String
    public let logicalSize: Int64
    public let physicalSize: Int64
    public let isCompressed: Bool
    public let type: CompressionType?
    public let reasons: [SafetyReason]

    public var name: String { (path as NSString).lastPathComponent }
    public var isExcluded: Bool { reasons.contains { $0.isHardExclusion } }
    public var savedBytes: Int64 { logicalSize - physicalSize }
}

public struct ScanResult: Sendable {
    public init() {}

    public var root: String = ""
    public var progress = ScanProgress()
    public var entries: [ScanEntry] = []
    public var hardLinkDuplicates = 0
    public var unreadableEntries = 0
    public var entriesTruncated = false
    public var duration: TimeInterval = 0
    public var volume = VolumeContext()

    /// Bytes already reclaimed by compression in place today.
    ///
    /// Derived only from files that are actually compressed. Using the whole-tree logical
    /// minus physical would count a sparse file's unallocated extents as savings — measured
    /// reporting "10.5 MB reclaimed" on a tree with 0% compression coverage.
    public var reclaimedBytes: Int64 {
        max(0, progress.compressedLogicalBytes - progress.compressedPhysicalBytes)
    }

    public var compressionCoverage: Double {
        progress.filesSeen > 0 ? Double(progress.compressedFiles) / Double(progress.filesSeen) : 0
    }

    /// The retained subset of eligible entries — bounded by `maxRetainedEntries`. For a
    /// count covering the whole tree use `progress.eligibleFiles`.
    public var eligibleEntries: [ScanEntry] {
        entries.filter { !$0.isExcluded && !$0.isCompressed }
    }
}

public enum ScanEvent: Sendable {
    case progress(ScanProgress)
    case finished(ScanResult)
}

public enum ScanEngine {

    /// Retaining every entry on a multi-million-file tree would cost hundreds of MB, so
    /// detail is capped and `entriesTruncated` is set. Aggregates always cover the whole
    /// tree — only the per-file list is bounded.
    public static let maxRetainedEntries = 200_000

    /// Progress is coalesced to this interval. Emitting per file makes the main actor the
    /// bottleneck long before the filesystem is.
    public static let progressInterval: TimeInterval = 0.1

    public static func scan(root: String, rules: SafetyRules = SafetyRules()) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let started = Date()
                let volume = VolumeContext.probe(path: root)
                var result = ScanResult()
                result.root = root
                result.volume = volume
                var progress = ScanProgress()
                var entries: [ScanEntry] = []
                var lastEmit = Date.distantPast
                var cancelled = false

                let walk = DirectoryWalker.walkFTS(root) { facts in
                    guard !cancelled else { return }
                    if Task.isCancelled { cancelled = true; return }

                    progress.filesSeen += 1
                    progress.logicalBytes += facts.logicalSize
                    progress.physicalBytes += facts.physicalSize
                    if facts.isCompressed { progress.compressedFiles += 1 }

                    let reasons = rules.evaluate(facts, volume: volume)
                    let excluded = reasons.contains { $0.isHardExclusion }
                    if excluded {
                        progress.excludedFiles += 1
                    } else if !facts.isCompressed {
                        progress.eligibleFiles += 1
                        progress.eligibleLogicalBytes += facts.logicalSize
                    }

                    if entries.count < maxRetainedEntries {
                        entries.append(ScanEntry(
                            inode: facts.inode,
                            path: facts.path,
                            logicalSize: facts.logicalSize,
                            physicalSize: facts.physicalSize,
                            isCompressed: facts.isCompressed,
                            type: facts.type,
                            reasons: reasons))
                    } else {
                        result.entriesTruncated = true
                    }

                    let now = Date()
                    if now.timeIntervalSince(lastEmit) >= progressInterval {
                        lastEmit = now
                        progress.currentPath = facts.path
                        continuation.yield(.progress(progress))
                    }
                }

                guard !cancelled, !Task.isCancelled else { continuation.finish(); return }

                // Aggregates come from the walker, which deduplicates by inode. Progress
                // counters above are per-callback and will over-count hard links, so the
                // authoritative byte totals are the walker's.
                progress.logicalBytes = walk.logicalTotal
                progress.physicalBytes = walk.physicalTotal
                progress.compressedFiles = walk.compressedFiles
                progress.compressedLogicalBytes = walk.compressedLogical
                progress.compressedPhysicalBytes = walk.compressedPhysical
                progress.directoriesSeen = walk.directories
                progress.currentPath = nil

                result.progress = progress
                result.entries = entries
                result.hardLinkDuplicates = walk.hardLinkDuplicates
                result.unreadableEntries = walk.errors
                result.duration = Date().timeIntervalSince(started)

                continuation.yield(.finished(result))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
