import Foundation
import Testing
@testable import PomaceCore
@testable import PomaceApp

@Suite("issue 1 app state")
@MainActor
struct ScanModelTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<250 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), "Timed out waiting for the model or fake compressor")
    }

    @Test("folder switching reuses results, while Rescan fetches new files")
    func recentScans() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceModel-\(UUID())")
        let a = directory.appendingPathComponent("a")
        let b = directory.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ScanModel(store: nil, installation: nil,
                              log: MutationLog(url: directory.appendingPathComponent("log")))
        model.select(a.path)
        try await waitUntil { model.result != nil }
        model.select(b.path)
        try await waitUntil { model.result != nil }
        try Data(repeating: 65, count: 4096).write(to: a.appendingPathComponent("new.txt"))
        model.select(a.path)
        #expect(!model.isScanning)
        #expect(model.showingRecentScan)
        #expect(model.result?.progress.filesSeen == 0)
        model.rescan()
        #expect(!model.showingRecentScan)
        try await waitUntil { model.result != nil }
        #expect(model.result?.progress.filesSeen == 1)
    }

    @Test("Stop receives the final outcome and preserves a newly selected folder")
    func stopping() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceModelStop-\(UUID())")
        let root = directory.appendingPathComponent("files")
        let other = directory.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("compressor")
        try """
        #!/bin/sh
        touch "$0.started"
        attempts=0
        while [ ! -f "$0.release" ] && [ "$attempts" -lt 250 ]; do
            sleep 0.02
            attempts=$((attempts + 1))
        done
        test -f "$0.release"
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try Data(repeating: 65, count: 4096).write(to: root.appendingPathComponent("test.txt"))
        let installation = ToolInstallation(source: .userConfigured(binary.path), capabilities:
            ToolCapabilities(version: nil, compressors: ["lzfse"], supportsVerify: true,
                             supportsLevel: false, supportsMinimumRatio: true, rawUsage: ""))
        let model = ScanModel(store: nil, installation: installation,
                              log: MutationLog(url: directory.appendingPathComponent("log")))
        model.select(root.path)
        try await waitUntil { model.result != nil }
        model.startCompress()
        try await waitUntil { FileManager.default.fileExists(atPath: binary.path + ".started") }
        model.cancelRun()
        #expect(model.isStopping)
        #expect(model.isRunning)
        model.select(other.path)
        try Data().write(to: URL(fileURLWithPath: binary.path + ".release"))
        try await waitUntil { !model.isRunning && !model.isStopping && model.result != nil }
        guard case .finished(let outcome) = model.runState else {
            Issue.record("Stop did not deliver a finished outcome")
            return
        }
        #expect(outcome.wasCancelled)
        #expect(model.selectedPath == other.path)
        #expect(model.result?.root == other.path)
        model.select(root.path)
        #expect(model.isScanning) // The pre-mutation snapshot was invalidated.
        try await waitUntil { model.result != nil }
    }
}
