import Foundation
import Testing
import Sparkle
@testable import PomaceCore
@testable import PomaceApp

@Suite("Sparkle sweep interlock")
@MainActor
struct UpdatesTests {
    @Test func postponesWhileSweepHeld() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceUpdates-\(UUID())")
        let url = directory.appendingPathComponent("sweep.lock")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lock = try #require(SweepLock.acquire(at: url))
        defer { lock.release() }
        let updates = Updates(startingUpdater: false, lockURL: url, pollInterval: 0.05)
        var invocations = 0
        #expect(SweepLock.isHeld(at: url))
        let postponed = updates.updater(updates.updater, shouldPostponeRelaunchForUpdate: .empty()) {
            invocations += 1
        }
        #expect(postponed)
        try await Task.sleep(for: .milliseconds(120))
        #expect(invocations == 0)
        lock.release()
        for _ in 0..<50 {
            if invocations == 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(invocations == 1)
        try await Task.sleep(for: .milliseconds(120))
        #expect(invocations == 1)
    }

    @Test(arguments: [CompressionOperation.compress, .decompress], [false, true])
    func inAppRunHoldsLockThroughFailure(operation: CompressionOperation, administrator: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceAppLock-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sweep.lock")
        let missing = directory.appendingPathComponent("missing-compressor").path
        #expect(!FileManager.default.fileExists(atPath: missing))
        let installation = ToolInstallation(source: .custom(missing), capabilities:
            ToolCapabilities(version: nil, compressors: ["lzfse"], supportsVerify: true,
                             supportsLevel: false, supportsMinimumRatio: true, rawUsage: ""))
        let model = ScanModel(store: nil,
            resolution: CompressorResolution(installation: installation, customRejection: nil),
            log: MutationLog(url: directory.appendingPathComponent("log")), sweepLockURL: url)
        model.selectedPath = "/Applications/Example.app"
        var result = ScanResult()
        result.root = model.selectedPath!
        result.entries = [ScanEntry(inode: 1, path: result.root + "/Contents/file", logicalSize: 4096,
                                   physicalSize: 4096, isCompressed: operation == .decompress,
                                   type: nil, reasons: [.applicationBundle])]
        model.state = .done(result)
        model.useAdministratorPrivileges = administrator
        #expect(!SweepLock.isHeld(at: url))
        if operation == .compress { model.startCompress() }
        else { model.confirmDecompress() }
        if administrator {
            #expect(model.confirmingAdministrator)
            #expect(!SweepLock.isHeld(at: url))
            model.confirmAdministrator()
        }
        #expect(model.isRunning)
        #expect(SweepLock.isHeld(at: url))
        for _ in 0..<100 {
            if !model.isRunning { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .refused(let error) = model.runState else {
            Issue.record("The missing compressor did not fail the run")
            return
        }
        #expect(error.contains("unavailable"))
        #expect(!SweepLock.isHeld(at: url))
    }

    @Test func headlessArgumentsCreateNoUpdater() {
        for flag in ["--sweep-all", "--sweep-now", "--register-sweeps", "--unregister-sweeps", "--service-status"] {
            #expect(!Main.shouldCreateUpdater(arguments: ["Pomace", flag]))
        }
        #expect(Main.shouldCreateUpdater(arguments: ["Pomace"]))
        #expect(Main.shouldCreateUpdater(arguments: ["Pomace", "--scan", "/tmp/alex"]))
    }
}
