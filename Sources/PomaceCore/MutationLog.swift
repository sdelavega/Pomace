import Foundation

/// An append-only record of every file-modifying operation.
///
/// SAFETY.md rule 9. When something does go wrong, this is the only thing that will explain
/// it — so it is written eagerly, flushed per line, and never buffered across a run.
public final class MutationLog: @unchecked Sendable {

    private let handle: FileHandle?
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

    public init(url: URL? = nil) {
        let target = url ?? Self.defaultURL
        if !FileManager.default.fileExists(atPath: target.path) {
            FileManager.default.createFile(atPath: target.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: target)
        try? handle?.seekToEnd()
    }

    deinit { try? handle?.close() }

    private func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard let data = "[\(formatter.string(from: Date()))] \(line)\n".data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
        // No buffering: a crash mid-run must still leave the record behind.
        try? handle?.synchronize()
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
