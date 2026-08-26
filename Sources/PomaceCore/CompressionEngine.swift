import Foundation

public enum CompressionOperation: String, Sendable {
    case compress, decompress
    public var verb: String { self == .compress ? "Compressing" : "Decompressing" }
}

public struct CompressionProgress: Sendable {
    public var filesTotal = 0
    public var filesProcessed = 0
    public var bytesProcessed: Int64 = 0
    public var currentPath: String?
    public var failures = 0
    public init() {}
    public var fraction: Double {
        filesTotal > 0 ? Double(filesProcessed) / Double(filesTotal) : 0
    }
}

public struct CompressionFailure: Sendable, Identifiable {
    public let id = UUID()
    public let path: String
    public let message: String
    /// Plain-language next step. An error the user can't act on is only half-reported.
    public let remedy: String
}

public struct CompressionOutcome: Sendable {
    public var operation: CompressionOperation = .compress
    public var filesAttempted = 0
    public var filesSucceeded = 0
    public var failures: [CompressionFailure] = []
    public var bytesBefore: Int64 = 0
    public var bytesAfter: Int64 = 0
    public var duration: TimeInterval = 0
    public var wasCancelled = false
    public var settings = CompressionSettings()
    public init() {}

    public var bytesReclaimed: Int64 { bytesBefore - bytesAfter }
}

public enum CompressionEvent: Sendable {
    case started(CompressionProgress)
    case progress(CompressionProgress)
    case finished(CompressionOutcome)
    case failed(String)
}

public enum CompressionEngineError: Error, CustomStringConvertible {
    case afsctoolMissing
    case insufficientFreeSpace(needed: Int64, available: Int64)
    case nothingToDo

    public var description: String {
        switch self {
        case .afsctoolMissing:
            "afsctool isn't installed. Pomace can install it for you."
        case .insufficientFreeSpace(let needed, let available):
            "Not enough free space to work safely — \(ByteFormat.short(available)) available, "
            + "\(ByteFormat.short(needed)) needed. Compression isn't atomic and needs room to work."
        case .nothingToDo:
            "Nothing here needs compressing."
        }
    }
}

public enum CompressionEngine {

    /// Files per afsctool invocation.
    ///
    /// Pomace passes explicit file lists rather than handing afsctool a directory. That is
    /// what makes cancellation land on a file boundary — we stop between batches, never
    /// mid-file — and it guarantees we only ever touch paths that passed a safety check at
    /// mutation time, per SAFETY.md rules 4 and 10.
    public static let batchSize = 128

    /// argv has a hard limit; long paths could otherwise overflow it well before `batchSize`.
    public static let maxArgumentBytes = 128 * 1024

    /// Refuse to start below this much free space. Compression is not atomic.
    public static let freeSpaceFloor: Int64 = 1024 * 1024 * 1024

    public static func run(operation: CompressionOperation,
                           paths: [String],
                           root: String,
                           installation: AfsctoolInstallation,
                           plan: CompressionPlan,
                           rules: SafetyRules = SafetyRules(),
                           logger: MutationLog? = nil) -> AsyncStream<CompressionEvent> {

        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let started = Date()
                var outcome = CompressionOutcome()
                outcome.operation = operation
                outcome.settings = plan.settings

                // --- preconditions ---
                let required = requiredFreeSpace(at: root)
                if let free = freeSpace(at: root), free < required {
                    continuation.yield(.failed(
                        CompressionEngineError.insufficientFreeSpace(
                            needed: required, available: free).description))
                    continuation.finish(); return
                }

                // --- re-evaluate safety at mutation time (SAFETY.md rule 10) ---
                let volume = VolumeContext.probe(path: root)
                // Hard links share an inode, and afsctool corrupts a file when it processes
                // the same inode more than once in a run — measured at 100% loss with -J1 and
                // roughly 8% with -J2, with a directory argument as well as explicit paths,
                // and `-f` does not prevent it. Passing exactly one path per inode is both
                // safe and complete: compressing one link compresses every link, because they
                // are the same file. See docs/M2-FINDINGS.md.
                var seenInodes = Set<UInt64>()
                var skippedLinks = 0

                var eligible: [(path: String, size: Int64)] = []
                for p in paths {
                    guard let f = FileInspector.inspect(p) else { continue }
                    if f.linkCount > 1, !seenInodes.insert(f.inode).inserted {
                        skippedLinks += 1
                        continue
                    }
                    if operation == .compress {
                        // Thorough pass here: the scan's fast pass skips the resource-fork
                        // probe, and a cached verdict is never trusted for a mutation.
                        guard !rules.isExcluded(f, volume: volume, depth: .thorough) else { continue }
                        guard !f.isCompressed else { continue }
                    } else {
                        guard f.isCompressed else { continue }
                    }
                    eligible.append((p, f.logicalSize))
                }

                guard !eligible.isEmpty else {
                    continuation.yield(.failed(CompressionEngineError.nothingToDo.description))
                    continuation.finish(); return
                }

                // Smallest first, globally — the largest files land last so a low-space
                // failure cannot strand a run that has already banked the small wins.
                if plan.settings.sortBySize {
                    eligible.sort { $0.size < $1.size }
                }

                outcome.bytesBefore = eligible.reduce(0) { $0 + physical($1.path) }
                var progress = CompressionProgress()
                progress.filesTotal = eligible.count
                continuation.yield(.started(progress))
                logger?.begin(operation: operation, root: root, fileCount: eligible.count,
                              arguments: plan.arguments)
                if skippedLinks > 0 {
                    logger?.note("collapsed \(skippedLinks) hard-linked path(s) to one path per inode")
                }

                let baseArgs = operation == .compress
                    ? plan.arguments
                    : CompressionPolicy.decompressArguments()

                assert(!baseArgs.contains { CompressionPolicy.forbiddenFlags.contains($0) },
                       "forbidden flag reached the argv")

                // --- batches ---
                var index = 0
                while index < eligible.count {
                    if Task.isCancelled {
                        outcome.wasCancelled = true
                        break
                    }
                    var batch: [String] = []
                    var bytes = 0
                    while index < eligible.count, batch.count < batchSize,
                          bytes < maxArgumentBytes {
                        batch.append(eligible[index].path)
                        bytes += eligible[index].path.utf8.count + 1
                        index += 1
                    }

                    let result = Subprocess.capture(installation.path, baseArgs + batch)
                    outcome.filesAttempted += batch.count

                    if result.succeeded {
                        outcome.filesSucceeded += batch.count
                    } else {
                        // A batch failure is not fatal: verify each file individually so one
                        // bad path doesn't discard the whole run's progress.
                        for p in batch {
                            let single = Subprocess.capture(installation.path, baseArgs + [p])
                            if single.succeeded {
                                outcome.filesSucceeded += 1
                            } else {
                                let failure = describeFailure(path: p, output: single.combined)
                                outcome.failures.append(failure)
                                logger?.failure(path: p, message: failure.message)
                            }
                        }
                    }

                    progress.filesProcessed = min(index, eligible.count)
                    progress.failures = outcome.failures.count
                    progress.currentPath = batch.last
                    progress.bytesProcessed = eligible.prefix(index).reduce(0) { $0 + $1.size }
                    continuation.yield(.progress(progress))
                }

                // --- post-run truth: re-measure natively, don't trust afsctool's summary ---
                outcome.bytesAfter = eligible.prefix(index).reduce(0) { $0 + physical($1.path) }
                outcome.duration = Date().timeIntervalSince(started)
                logger?.end(outcome: outcome)
                continuation.yield(.finished(outcome))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func physical(_ path: String) -> Int64 {
        FileInspector.inspect(path)?.physicalSize ?? 0
    }

    /// Free space, preferring the "important usage" figure (which accounts for purgeable
    /// space) but falling back to statfs.
    ///
    /// The URL resource key returns 0 on some volumes — disk images among them — and a
    /// naive read of that number made the engine refuse every run on a test image while
    /// reporting "0 bytes available". Treat a zero or missing value as "ask statfs", never
    /// as "the disk is full".
    public static func freeSpace(at path: String) -> Int64? {
        if let v = try? URL(fileURLWithPath: path)
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let bytes = v.volumeAvailableCapacityForImportantUsage, bytes > 0 {
            return Int64(bytes)
        }
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        return Int64(fs.f_bavail) * Int64(fs.f_bsize)
    }

    /// The floor scales down on small volumes: a 3 GB disk image should not be told it needs
    /// 1 GB free before it may compress anything.
    static func requiredFreeSpace(at path: String) -> Int64 {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return freeSpaceFloor }
        let total = Int64(fs.f_blocks) * Int64(fs.f_bsize)
        return min(freeSpaceFloor, max(64 * 1024 * 1024, total / 20))
    }

    /// Turns afsctool's output into something the user can act on.
    static func describeFailure(path: String, output: String) -> CompressionFailure {
        let lower = output.lowercased()
        let remedy: String
        if lower.contains("permission") || lower.contains("denied") {
            remedy = "Check that you have permission to modify this file, or grant Pomace Full Disk Access."
        } else if lower.contains("no space") || lower.contains("disk full") {
            remedy = "Free up disk space and try again."
        } else if lower.contains("resource fork") {
            remedy = "This file already uses its resource fork, so it can't be compressed. It will be skipped."
        } else if lower.contains("read-only") {
            remedy = "This file is on a read-only volume."
        } else {
            remedy = "Left unchanged. The file itself was not modified."
        }
        let message = output
            .split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init) ?? "afsctool reported an error"
        return CompressionFailure(path: path, message: message, remedy: remedy)
    }
}
