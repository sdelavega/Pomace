import Foundation
import Testing
@testable import PomaceCore

@Suite("subprocess output")
struct SubprocessOutputTests {
    @Test("drains stderr while stdout remains open")
    func largeStderr() {
        // A watchdog makes the old implementation fail rather than hang the test suite.
        let script = """
        (sleep 5; kill -TERM $$) >/dev/null 2>&1 &
        watchdog=$!
        head -c 1048576 /dev/zero >&2
        printf done
        kill "$watchdog"
        wait "$watchdog" 2>/dev/null
        exit 0
        """
        let output = Subprocess.capture("/bin/sh", ["-c", script])
        #expect(output.code == 0)
        #expect(output.stdout == "done")
        #expect(output.stderr.utf8.count == 1_048_576)
    }

    @Test("preserves both streams and the exit status")
    func failureOutput() {
        let output = Subprocess.capture("/bin/sh", ["-c", "printf out; printf err >&2; exit 7"])
        #expect(output.stdout == "out")
        #expect(output.stderr == "err")
        #expect(output.code == 7)
    }
}

@Suite("recent scan cache")
struct ScanCacheTests {
    private func snapshot(_ path: String) -> ScanResult {
        var result = ScanResult()
        result.root = path
        result.progress.filesSeen = 42
        return result
    }

    @Test("reuses a recent scan and expires it without extending its age")
    func expiry() {
        var cache = ScanCache(lifetime: 60)
        let now = Date(timeIntervalSince1970: 1000)
        cache.insert(snapshot("/example/a"), now: now)
        #expect(cache.result(for: "/example/a", now: now.addingTimeInterval(30))?.progress.filesSeen == 42)
        #expect(cache.result(for: "/example/a", now: now.addingTimeInterval(60)) == nil)
    }

    @Test("evicts the oldest snapshot to bound retained entries")
    func eviction() {
        var cache = ScanCache(capacity: 2)
        let now = Date(timeIntervalSince1970: 1000)
        for (index, path) in ["/example/a", "/example/b", "/example/c"].enumerated() {
            cache.insert(snapshot(path), now: now.addingTimeInterval(Double(index)))
        }
        #expect(cache.result(for: "/example/a", now: now.addingTimeInterval(3)) == nil)
        #expect(cache.result(for: "/example/b", now: now.addingTimeInterval(3)) != nil)
        #expect(cache.result(for: "/example/c", now: now.addingTimeInterval(3)) != nil)
    }

    @Test("mutation invalidates ancestors and descendants but retains siblings")
    func invalidation() {
        var cache = ScanCache()
        for path in ["/example", "/example/a/sub", "/example/ab"] { cache.insert(snapshot(path)) }
        cache.invalidate("/example/a")
        #expect(cache.result(for: "/example") == nil)
        #expect(cache.result(for: "/example/a/sub") == nil)
        #expect(cache.result(for: "/example/ab") != nil)
    }
}

@Suite("safe compression cancellation")
struct CompressionCancellationTests {
    @Test("finishes the active batch, delivers an outcome, and starts no more batches",
          arguments: [1, CompressionEngine.batchSize + 1])
    func activeBatch(fileCount: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceCancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("fake-compressor")
        // A release barrier proves that cancellation leaves the active process intact.
        try """
        #!/bin/sh
        printf 'call\\n' >> "$0.calls"
        touch "$0.started"
        attempts=0
        while [ ! -f "$0.release" ] && [ "$attempts" -lt 250 ]; do
            sleep 0.02
            attempts=$((attempts + 1))
        done
        test -f "$0.release" || exit 9
        touch "$0.finished"
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        var paths: [String] = []
        for index in 0..<fileCount {
            let file = directory.appendingPathComponent("file-\(index).txt")
            try Data(repeating: 65, count: 4096).write(to: file)
            paths.append(file.path)
        }
        let installation = ToolInstallation(source: .userConfigured(binary.path), capabilities:
            ToolCapabilities(version: nil, compressors: ["lzfse"], supportsVerify: true,
                             supportsLevel: false, supportsMinimumRatio: true, rawUsage: ""))
        let cancellation = CompressionCancellation()
        let consumer = Task {
            var final: CompressionOutcome?
            for await event in CompressionEngine.run(operation: .compress, paths: paths,
                    root: directory.path, installation: installation,
                    plan: CompressionPolicy.plan(), cancellation: cancellation) {
                if case .finished(let outcome) = event { final = outcome }
            }
            return final
        }
        for _ in 0..<250 {
            if FileManager.default.fileExists(atPath: binary.path + ".started") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let started = FileManager.default.fileExists(atPath: binary.path + ".started")
        cancellation.request()
        try Data().write(to: URL(fileURLWithPath: binary.path + ".release"))
        let final = await consumer.value
        #expect(started)
        let outcome = try #require(final)
        #expect(outcome.wasCancelled)
        #expect(outcome.bytesReclaimed == 0) // The fake compressor changes no files.
        #expect(outcome.filesAttempted == min(fileCount, CompressionEngine.batchSize))
        #expect(FileManager.default.fileExists(atPath: binary.path + ".finished"))
        let calls = try String(contentsOfFile: binary.path + ".calls", encoding: .utf8)
        #expect(calls == "call\n")
    }
}
