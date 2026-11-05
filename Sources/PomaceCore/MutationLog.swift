import Foundation

/// An append-only record of every file-modifying operation.
///
/// SAFETY.md rule 9. When something does go wrong, this is the only thing that will explain
/// it — so it is written eagerly, flushed per line, and never buffered across a run.
public final class MutationLog: @unchecked Sendable {

    public let url: URL
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomace/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mutations.log")
    }

    /// The log is rotated when it reaches this size: the current file becomes
    /// `<name>.1.log`, replacing the previous one, so at most about twice this is kept.
    public static let rotationSize: UInt64 = 8 * 1024 * 1024

    /// Where the previous generation of a log lives after rotation.
    public static func rotatedURL(for url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("1.log")
    }

    /// Rotates at open, not mid-write: both the app and every hourly sweep open the log, so
    /// this runs often enough, and a run's BEGIN/END lines never straddle two files.
    /// Writers reopen the file per line (see `write`), so a rotation between lines is
    /// seamless and loses nothing.
    static func rotateIfNeeded(_ url: URL, limit: UInt64) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64,
              size >= limit else { return }
        // rename(2) replaces the old generation atomically. Two processes racing a
        // rotation each replace the other's generation in turn: one generation is lost,
        // never written data — within the "about twice the limit" budget above.
        _ = rename(url.path, rotatedURL(for: url).path)
    }

    public init(url: URL? = nil, rotationSize: UInt64 = MutationLog.rotationSize) {
        let target = url ?? Self.defaultURL
        self.url = target
        Self.rotateIfNeeded(target, limit: rotationSize)
        if !FileManager.default.fileExists(atPath: target.path) {
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }
    }

    private func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard let data = "[\(formatter.string(from: Date()))] \(line)\n".data(using: .utf8) else { return }
        // Open per line, not once per process. Lines are rare — per-file failures and a
        // BEGIN/END pair per run — so the cost is nothing next to what a persistent handle
        // costs: after another process rotates the file, the old handle appends to an
        // unlinked inode and this process's lines silently vanish from disk, losing the
        // SAFETY.md rule 9 record for the rest of the session. Reopening also retries a
        // transient open failure instead of dropping every later line.
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        // No buffering: a crash mid-run must still leave the record behind.
        try? handle.synchronize()
        try? handle.close()
    }

    public func begin(operation: CompressionOperation, root: String,
                      fileCount: Int, arguments: [String]) {
        write("BEGIN \(operation.rawValue) root=\(root) files=\(fileCount) args=\(arguments.joined(separator: " "))")
    }

    public func failure(path: String, message: String) {
        write("FAIL path=\(path) message=\(message.prefix(200))")
    }

    public func end(outcome: CompressionOutcome) {
        write(String(format: "END %@ attempted=%d succeeded=%d failed=%d reclaimed=%lld duration=%.2fs cancelled=%@",
                     outcome.operation.rawValue, outcome.filesAttempted, outcome.filesSucceeded,
                     outcome.failures.count, outcome.bytesReclaimed, outcome.duration,
                     outcome.wasCancelled ? "yes" : "no"))
    }

    public func note(_ message: String) { write("NOTE \(message)") }
}
