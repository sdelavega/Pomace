import Foundation

public enum CompressionOperation: String, Sendable {
    case compress, decompress
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

public enum SkipRemedy: Sendable, Equatable {
    case hardLinked(otherFiles: Int), emptyFile, unreadable, unwritable, insufficientSaving
    case decompressionFailed, fileMissing, diskFull, resourceFork, readOnly, unchanged
}

public enum CompressionFailureMessage: Sendable, Equatable {
    case classified(SkipRemedy)
    case toolOutput(String)
    case compressorError
}

public struct CompressionFailure: Sendable, Identifiable {
    /// Whether this needs the user's attention, or is the tool correctly declining.
    ///
    /// Most non-compressed files are `.skipped`: incompressible media, files below the
    /// savings threshold, hard-linked files. Presenting those as failures is noise, and
    /// noise is how a warnings list gets ignored — which then hides the real `.failed`
    /// entries that do need action.
    public enum Kind: Sendable { case skipped, failed }

    public let id = UUID()
    public let path: String
    public let message: CompressionFailureMessage
    public let remedy: SkipRemedy
    public var kind: Kind = .skipped

    public init(path: String, message: CompressionFailureMessage? = nil, remedy: SkipRemedy, kind: Kind? = nil) {
        self.path = path; self.message = message ?? .classified(remedy); self.remedy = remedy
        if let kind { self.kind = kind }
        else {
            switch remedy {
            case .hardLinked, .emptyFile, .insufficientSaving: self.kind = .skipped
            default: self.kind = .failed
            }
        }
    }
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

    /// Entries that genuinely need attention. `skipped` files are reported quietly.
    public var realFailures: [CompressionFailure] { failures.filter { $0.kind == .failed } }
    public var skipped: [CompressionFailure] { failures.filter { $0.kind == .skipped } }
}

public enum CompressionEvent: Sendable {
    case started(CompressionProgress)
    case progress(CompressionProgress)
    case finished(CompressionOutcome)
    case failed(CompressionEngineError)
}

public enum CompressionEngineError: Error, Sendable, Equatable, Codable {
    case toolMissing
    case insufficientFreeSpace(needed: Int64, available: Int64)
    case nothingToDo
    case compressorChanged(confirmed: String, resolved: String)
    case administratorUnsupported
    case compressorUnavailable
    case readOnlyVolume
    case safetyMetadataUnreadable(path: String)
    case verificationRequired
    case alreadyRunning
}

/// Requests a safe stop without cancelling the consumer of the final outcome.
public final class CompressionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    public init() {}
    public func request() { lock.lock(); defer { lock.unlock() }; requested = true }
    public var isRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}

public enum CompressionEngine {

    /// Files per compressor invocation.
    ///
    /// Pomace passes explicit file lists rather than handing the compressor a directory. That is
    /// what makes cancellation land on a file boundary — we stop between batches, never
    /// mid-file — and it guarantees we only ever touch paths that passed a safety check at
    /// mutation time, per SAFETY.md rules 4 and 10.
    public static let batchSize = 128

    /// argv has a hard limit; long paths could otherwise overflow it well before `batchSize`.
    public static let maxArgumentBytes = 128 * 1024

    /// Refuse to start below this much free space. Atomic replacement still needs workspace.
    public static let freeSpaceFloor: Int64 = 1024 * 1024 * 1024

    public static func run(operation: CompressionOperation,
                           paths: [String],
                           root: String,
                           installation: ToolInstallation,
                           plan: CompressionPlan,
                           rules: SafetyRules = SafetyRules(),
                           logger: MutationLog? = nil,
                           cancellation: CompressionCancellation? = nil,
                           executor: CompressionExecutor = .standard,
                           resolveCompressor: @escaping @Sendable (String?) -> CompressorResolution = {
                               CompressorTool.resolve(customPath: $0)
                           }) -> AsyncStream<CompressionEvent> {

        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let started = Date()
                var outcome = CompressionOutcome()
                outcome.operation = operation
                outcome.settings = plan.settings

                // --- preconditions ---
                if executor.isAdministrator && !AdministratorAccess.supports(root: root) {
                    continuation.yield(.failed(.administratorUnsupported))
                    continuation.finish(); return
                }
                let customPath: String?
                switch installation.source {
                case .custom(let path): customPath = path
                case .bundled: customPath = nil
                }
                let confirmedPath = installation.path
                guard let installation = resolveCompressor(customPath).installation else {
                    continuation.yield(.failed(.compressorUnavailable))
                    continuation.finish(); return
                }
                // Elevated execution must use the exact compressor named in the confirmation.
                if executor.isAdministrator && installation.path != confirmedPath {
                    continuation.yield(.failed(CompressionEngineError.compressorChanged(
                        confirmed: confirmedPath, resolved: installation.path)))
                    continuation.finish(); return
                }
                let required = requiredFreeSpace(at: root)
                if let free = freeSpace(at: root), free < required {
                    continuation.yield(.failed(
                        CompressionEngineError.insufficientFreeSpace(
                            needed: required, available: free)))
                    continuation.finish(); return
                }

                // --- re-evaluate safety at mutation time (SAFETY.md rule 10) ---
                let volume = VolumeContext.probe(path: root)
                guard !volume.isReadOnly else {
                    continuation.yield(.failed(.readOnlyVolume))
                    continuation.finish(); return
                }
                // applesauce refuses any file with more than one link, so hard-linked files
                // simply cannot be compressed. Pomace filters them here so they are reported
                // as a named exclusion rather than silently counted as attempted-and-failed.
                //
                // (Under afsctool this filter was a data-loss guard rather than a courtesy —
                // see docs/M2-FINDINGS.md. applesauce declines the hazardous case outright,
                // which is why the pivot happened. ADR-0015.)
                var skippedLinks = 0

                var eligible: [(path: String, size: Int64, physicalBefore: Int64)] = []
                for requestedPath in paths {
                    let p = executor.isAdministrator
                        ? URL(fileURLWithPath: requestedPath).resolvingSymlinksInPath().standardized.path
                        : requestedPath
                    if Task.isCancelled || cancellation?.isRequested == true { break }
                    guard let f = FileInspector.inspect(p) else { continue }
                    if executor.isAdministrator {
                        // Never elevate a path outside the confirmed folder or hand a
                        // directory/symlink to a tool that can recursively walk it.
                        guard AdministratorAccess.permits(path: p, root: root), f.isRegularFile,
                              !rules.isExcluded(f, volume: volume, depth: .thorough) else { continue }
                        if operation == .compress, !f.isCompressed,
                           !AdministratorAccess.canInspectResourceFork(at: p) {
                            continuation.yield(.failed(.safetyMetadataUnreadable(path: p)))
                            continuation.finish(); return
                        }
                    }
                    if f.linkCount > 1 {
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
                    eligible.append((p, f.logicalSize, f.physicalSize))
                }

                if Task.isCancelled || cancellation?.isRequested == true {
                    outcome.wasCancelled = true
                    outcome.duration = Date().timeIntervalSince(started)
                    continuation.yield(.finished(outcome))
                    continuation.finish(); return
                }

                guard !eligible.isEmpty else {
                    continuation.yield(.failed(CompressionEngineError.nothingToDo))
                    continuation.finish(); return
                }

                // Smallest first, globally. The largest files land last so a low-space
                // failure cannot strand a run that has already banked the small wins.
                // applesauce has no sort flag of its own, so Pomace does this itself — which
                // is better anyway, since ordering now spans every batch rather than each
                // invocation separately.
                eligible.sort { $0.size < $1.size }

                outcome.bytesBefore = eligible.reduce(0) { $0 + physical($1.path) }
                var progress = CompressionProgress()
                progress.filesTotal = eligible.count
                continuation.yield(.started(progress))
                logger?.begin(operation: operation, root: root, fileCount: eligible.count,
                              arguments: plan.arguments)
                logger?.note(executor.isAdministrator ? "access=administrator (interactive)" : "access=current user")
                if skippedLinks > 0 {
                    logger?.note("skipped \(skippedLinks) hard-linked path(s) — \(CompressorTool.displayName) cannot compress them")
                }

                let baseArgs = operation == .compress
                    ? plan.arguments
                    : CompressionPolicy.decompressArguments()

                // applesauce verifies only when asked. Reaching the filesystem without this
                // flag would mean compressing without ever checking the result reads back.
                guard operation == .decompress || baseArgs.contains("--verify") else {
                    continuation.yield(.failed(.verificationRequired))
                    continuation.finish(); return
                }

                // --- batches ---
                var index = 0
                while index < eligible.count {
                    if Task.isCancelled || cancellation?.isRequested == true {
                        outcome.wasCancelled = true
                        break
                    }
                    var batch: [String] = []
                    var bytes = 0
                    while index < eligible.count, batch.count < batchSize,
                          bytes < maxArgumentBytes {
                        let path = eligible[index].path
                        batch.append(path)
                        if executor.isAdministrator {
                            // The shell checks repeat each quoted path twice in addition
                            // to argv. Account for quoting expansion in the command budget.
                            let quoteExpansion = path.utf8.reduce(0) { $0 + ($1 == 39 ? 4 : 0) }
                            bytes += 3 * (path.utf8.count + quoteExpansion + 2) + 180
                        } else {
                            bytes += path.utf8.count + 1
                        }
                        index += 1
                    }

                    // This is a batch boundary, not a claim that applesauce exposes its
                    // currently active file. Publish before the blocking invocation.
                    progress.currentPath = batch.first
                    continuation.yield(.progress(progress))
                    let batchStarted = Date()
                    logger?.note("batch BEGIN files=\(batch.count) first=\(batch.first ?? "") last=\(batch.last ?? "")")
                    let invocationOutput: Subprocess.Output?
                    switch executor.invoke(installation.path, baseArgs + ["--"] + batch) {
                    case .authorizationCancelled:
                        // This batch never started. Keep the outcome of earlier batches.
                        index -= batch.count
                        outcome.wasCancelled = true
                        logger?.note("administrator authorization cancelled — no further batches")
                        invocationOutput = nil
                    case .completed(let output): invocationOutput = output
                    }
                    guard let result = invocationOutput else { break }
                    logger?.note("batch END exit=\(result.code) duration=\(Date().timeIntervalSince(batchStarted))s")
                    outcome.filesAttempted += batch.count

                    // applesauce exits 0 even for a missing or unreadable path, and never
                    // names the files it skipped — it only reports a summary count. So the
                    // per-file verdict comes from re-inspecting the filesystem, which is the
                    // more trustworthy source anyway (ADR-0002).
                    for p in batch {
                        guard let after = FileInspector.inspect(p) else {
                            let f = CompressionFailure(path: p, remedy: .fileMissing, kind: .failed)
                            outcome.failures.append(f)
                            logger?.failure(path: p, message: String(describing: f.message))
                            continue
                        }
                        let wanted = operation == .compress
                        if after.isCompressed == wanted {
                            outcome.filesSucceeded += 1
                        } else {
                            let f: CompressionFailure
                            if !result.succeeded {
                                var failure = describeFailure(path: p, output: result.combined)
                                failure.kind = .failed
                                f = failure
                            } else {
                                f = CompressionFailure(path: p, remedy: classifySkip(
                                    path: p, operation: operation, output: result.combined,
                                    isAdministrator: executor.isAdministrator))
                            }
                            outcome.failures.append(f)
                            logger?.failure(path: p, message: String(describing: f.message))
                        }
                    }

                    progress.filesProcessed = min(index, eligible.count)
                    progress.failures = outcome.realFailures.count
                    progress.currentPath = nil
                    progress.bytesProcessed = eligible.prefix(index).reduce(0) { $0 + $1.size }
                    continuation.yield(.progress(progress))
                    // An authorization or invocation error should not prompt again for
                    // every subsequent batch. Report it and retain completed work.
                    if !result.succeeded { break }
                }

                // A request during the final batch must also be acknowledged.
                outcome.wasCancelled = outcome.wasCancelled || Task.isCancelled || cancellation?.isRequested == true

                // --- post-run truth: re-measure natively, don't trust tool output ---
                // Compare the same attempted files on both sides. Unprocessed files
                // must not look like reclaimed space after a safe stop.
                outcome.bytesBefore = eligible.prefix(index).reduce(0) { $0 + $1.physicalBefore }
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

    /// Why a file came back in the state it started in.
    ///
    /// applesauce reports no per-file detail, so this reasons from the file itself. It
    /// deliberately prefers "skipped, here's why" over "failed" — most of these are the tool
    /// declining for a good reason, and calling that a failure would train users to ignore
    /// the list.
    static func classifySkip(path: String, operation: CompressionOperation,
                             output: String, isAdministrator: Bool = false) -> SkipRemedy {
        if operation == .compress {
            if let f = FileInspector.inspect(path) {
                if f.linkCount > 1 { return .hardLinked(otherFiles: Int(f.linkCount - 1)) }
                if f.logicalSize == 0 { return .emptyFile }
            }
            if !isAdministrator && access(path, R_OK) != 0 { return .unreadable }
            if !isAdministrator && (access(path, W_OK) != 0
                || access((path as NSString).deletingLastPathComponent, W_OK) != 0) {
                return .unwritable
            }
            return .insufficientSaving
        }
        return .decompressionFailed
    }

    /// Retained for the low-level error paths that still surface tool output.
    static func describeFailure(path: String, output: String) -> CompressionFailure {
        let lower = output.lowercased()
        let remedy: SkipRemedy
        if lower.contains("permission") || lower.contains("denied") {
            remedy = .unreadable
        } else if lower.contains("no space") || lower.contains("disk full") {
            remedy = .diskFull
        } else if lower.contains("resource fork") {
            remedy = .resourceFork
        } else if lower.contains("read-only") {
            remedy = .readOnly
        } else {
            remedy = .unchanged
        }
        let message = output
            .split(separator: "\n")
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { CompressionFailureMessage.toolOutput(String($0)) } ?? .compressorError
        return CompressionFailure(path: path, message: message, remedy: remedy, kind: .skipped)
    }
}
