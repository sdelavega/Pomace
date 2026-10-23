import Foundation
import Testing
@testable import PomaceCore

@Suite("sweep update interlock")
struct SweepLockTests {
    @Test func lockExcludesSecondHolder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceLock-\(UUID())")
        let url = directory.appendingPathComponent("sweep.lock")
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(!SweepLock.isHeld(at: url))
        let first = try #require(SweepLock.acquire(at: url))
        defer { first.release() }
        #expect(SweepLock.acquire(at: url) == nil)
        #expect(SweepLock.isHeld(at: url))
        first.release()
        first.release() // Releasing twice must not close a reused descriptor.
        #expect(!SweepLock.isHeld(at: url))
        let next = try #require(SweepLock.acquire(at: url))
        defer { next.release() }
        #expect(SweepLock.isHeld(at: url))
    }

    @Test func lockReleasedWhenRunThrows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceLockFailure-\(UUID())")
        let root = directory.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 65, count: 4096).write(to: root.appendingPathComponent("file.txt"))
        let lockURL = directory.appendingPathComponent("sweep.lock")
        let store = try Store(url: directory.appendingPathComponent("store.sqlite"))
        let runner = SweepRunner(store: store, log: MutationLog(url: directory.appendingPathComponent("log")),
                                 lockURL: lockURL, checkPreconditions: { _ in
                                     #expect(SweepLock.isHeld(at: lockURL))
                                     return nil
                                 })
        let missing = directory.appendingPathComponent("missing-compressor").path
        #expect(!FileManager.default.fileExists(atPath: missing))
        let installation = ToolInstallation(source: .custom(missing), capabilities:
            ToolCapabilities(version: nil, compressors: ["lzfse"], supportsVerify: true,
                             supportsLevel: false, supportsMinimumRatio: true, rawUsage: ""))
        let dir = Store.WatchedDirectory(id: 0, path: root.path, schedule: SweepSchedule(), mode: .automatic)
        let report = await runner.sweep(dir, installation: installation, lastRun: nil)
        // Engine errors are delivered as .failed events rather than thrown by its AsyncStream.
        #expect(report.deferral == nil)
        #expect(report.candidatesConsidered == 1)
        #expect(report.error != nil)
        #expect(!SweepLock.isHeld(at: lockURL))
        let next = try #require(SweepLock.acquire(at: lockURL))
        next.release()
    }
}
