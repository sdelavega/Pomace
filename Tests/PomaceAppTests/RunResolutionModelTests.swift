import Foundation
import Testing
@testable import PomaceCore
@testable import PomaceApp

@Suite("run resolution presentation")
@MainActor
struct RunResolutionModelTests {
    @Test func fallbackUpdatesModelAndReport() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("custom")
        let bundle = root.appendingPathComponent("bundled")
        let file = root.appendingPathComponent("file.txt")
        for binary in [custom, bundle] {
            try "#!/bin/sh\necho 'applesauce 0.5.30 lzfse --verify --minimum-compression-ratio'\n".write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        try Data(repeating: 65, count: 4096).write(to: file)
        let original = CompressorTool.resolve(customPath: custom.path, bundledURL: bundle, signatureIsValid: { _ in true })
        #expect(original.installation?.source == .custom(custom.resolvingSymlinksInPath().path))
        let model = ScanModel(store: nil, resolution: original,
                              log: MutationLog(url: root.appendingPathComponent("log")), sweepLockURL: root.appendingPathComponent("lock"))
        model.resolveCompressor = { path in
            CompressorTool.resolve(customPath: path, bundledURL: bundle, signatureIsValid: { _ in true })
        }
        model.selectedPath = root.path
        var result = ScanResult()
        result.root = root.path
        result.entries = [ScanEntry(inode: 1, path: file.path, logicalSize: 4096, physicalSize: 4096,
                                    isCompressed: false, type: nil, reasons: [])]
        model.state = .done(result)
        try FileManager.default.removeItem(at: custom)
        model.startCompress()
        for _ in 0..<200 {
            if !model.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .finished(let outcome) = model.runState else {
            Issue.record("The fallback run did not finish")
            return
        }
        #expect(outcome.filesAttempted == 1)
        #expect(model.resolution.installation?.source == .bundled(bundle.path))
        #expect(model.resolution.customRejection == .notFound)
        #expect(model.customCompressorRejectionText != nil)
        let report = DiagnosticsReport.render(DiagnosticsInput(appVersion: "test", build: "1", osVersion: "test",
            architecture: "test", compressor: model.resolution, agentRegistered: false, logLines: [], crashReports: [],
            scannedRoots: [], homeDirectory: URL(fileURLWithPath: "/Users/alex"), userName: "alex", hostName: "alex-mbp"))
        #expect(report.contains("Compressor: bundled"))
        #expect(report.contains("notFound"))
    }
}
