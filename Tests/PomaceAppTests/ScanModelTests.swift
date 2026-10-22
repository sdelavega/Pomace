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

    private func customCompressor(in directory: URL) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("applesauce")
        try """
        #!/bin/sh
        case "$*" in
            --version) echo 'applesauce 0.5.30' ;;
            'compress --help') echo 'lzfse --verify --minimum-compression-ratio' ;;
            *) exit 1 ;;
        esac
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return binary.resolvingSymlinksInPath().path
    }

    @Test("choosing a custom compressor persists and resolves it")
    func choosingCustomPersists() throws {
        let suite = "PomaceCustom-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let path = try customCompressor(in: directory)
        #expect(CompressorTool.probe(.custom(path)).capabilities.isUsable)
        #expect(defaults.string(forKey: CompressorTool.customPathDefaultsKey) == nil)
        let model = ScanModel(store: nil, defaults: defaults)
        model.setCustomCompressor(path)
        #expect(defaults.string(forKey: CompressorTool.customPathDefaultsKey) == path)
        #expect(model.resolution.installation?.source == .custom(path))
        let restored = ScanModel(store: nil, defaults: defaults)
        #expect(restored.resolution.installation?.source == .custom(path))
    }

    @Test("using the bundled compressor clears the custom choice")
    func useBundledClearsCustom() throws {
        let suite = "PomaceBundled-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let path = try customCompressor(in: directory)
        defaults.set(path, forKey: CompressorTool.customPathDefaultsKey)
        let model = ScanModel(store: nil, defaults: defaults)
        #expect(defaults.string(forKey: CompressorTool.customPathDefaultsKey) == path)
        #expect(model.resolution.installation?.source == .custom(path))
        model.setCustomCompressor(nil)
        #expect(defaults.string(forKey: CompressorTool.customPathDefaultsKey) == nil)
        #expect(model.resolution.installation?.source != .custom(path))
        #expect(model.resolution.customRejection == nil)
    }

    @Test("administrator confirmation names and warns about the custom compressor")
    func adminConfirmationNamesCustom() throws {
        let suite = "PomaceConfirmation-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let path = try customCompressor(in: directory)
        let model = ScanModel(store: nil, defaults: defaults)
        model.setCustomCompressor(path)
        #expect(model.resolution.installation?.source == .custom(path))
        model.selectedPath = "/Applications/Example.app"
        var result = ScanResult()
        result.root = model.selectedPath!
        result.entries = [ScanEntry(inode: 1, path: result.root + "/Contents/file", logicalSize: 4096,
                                   physicalSize: 4096, isCompressed: false, type: nil, reasons: [.applicationBundle])]
        model.state = .done(result)
        model.useAdministratorPrivileges = true
        model.startCompress()
        #expect(model.confirmingAdministrator)
        #expect(!model.isRunning)
        #expect(model.administratorConfirmationText.contains(path))
        #expect(model.administratorConfirmationText.contains("This is a compressor you chose, not the one bundled with Pomace. It will run with administrator privileges."))
        model.cancelAdministrator()
    }

    @Test("bundled administrator confirmation omits the custom compressor warning")
    func adminConfirmationNamesBundled() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceBundledConfirmation-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try customCompressor(in: directory)
        let installation = CompressorTool.probe(.bundled(path))
        #expect(installation.source == .bundled(path))
        #expect(installation.capabilities.isUsable)
        let model = ScanModel(store: nil, resolution: CompressorResolution(installation: installation, customRejection: nil))
        model.selectedPath = "/Applications/Example.app"
        var result = ScanResult()
        result.root = model.selectedPath!
        result.entries = [ScanEntry(inode: 1, path: result.root + "/Contents/file", logicalSize: 4096,
                                   physicalSize: 4096, isCompressed: false, type: nil, reasons: [.applicationBundle])]
        model.state = .done(result)
        model.useAdministratorPrivileges = true
        model.startCompress()
        #expect(model.confirmingAdministrator)
        #expect(!model.isRunning)
        #expect(model.administratorConfirmationText.contains(path))
        #expect(model.administratorConfirmationText.contains(result.root))
        #expect(!model.administratorConfirmationText.contains("not the one bundled"))
        model.cancelAdministrator()
    }

    @Test("custom rejection explains a missing file and the bundled fallback")
    func customRejectionExplainsFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceRejection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundled = try customCompressor(in: directory)
        let missing = directory.appendingPathComponent("missing").path
        #expect(!FileManager.default.fileExists(atPath: missing))
        let resolution = CompressorTool.resolve(customPath: missing, bundledURL: URL(fileURLWithPath: bundled),
                                               signatureIsValid: { _ in true })
        #expect(resolution.customRejection == .notFound)
        #expect(resolution.installation?.source == .bundled(bundled))
        let model = ScanModel(store: nil, resolution: resolution)
        let text = try #require(model.customCompressorRejectionText)
        #expect(text.contains("The chosen compressor could not be found."))
        #expect(text.contains("Pomace is using the bundled compressor."))
    }

    @Test("administrator compression requires confirmation and can be cancelled")
    func administratorConfirmation() {
        let model = ScanModel(store: nil, resolution: CompressorResolution(installation: ToolInstallation(
            source: .custom("/opt/homebrew/bin/applesauce"), capabilities:
                ToolCapabilities(version: nil, compressors: ["lzfse"], supportsVerify: true,
                                 supportsLevel: false, supportsMinimumRatio: true, rawUsage: "")), customRejection: nil))
        model.selectedPath = "/Applications/Example.app"
        var result = ScanResult()
        result.root = model.selectedPath!
        result.entries = [ScanEntry(inode: 1, path: result.root + "/Contents/file", logicalSize: 4096,
                                   physicalSize: 4096, isCompressed: false, type: nil, reasons: [.applicationBundle])]
        model.state = .done(result)
        model.useAdministratorPrivileges = true
        model.startCompress()
        #expect(model.confirmingAdministrator)
        #expect(!model.isRunning)
        #expect(model.administratorConfirmationText.contains("/Applications/Example.app"))
        #expect(model.administratorConfirmationText.contains("/opt/homebrew/bin/applesauce"))
        model.cancelAdministrator()
        #expect(!model.confirmingAdministrator)
        #expect(!model.isRunning)
        #expect(model.administratorConfirmationText.isEmpty)
        model.confirmAdministrator() // A cancelled request cannot be replayed.
        #expect(!model.isRunning)
    }

    @Test("folder switching reuses results, while Rescan fetches new files")
    func recentScans() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceModel-\(UUID())")
        let a = directory.appendingPathComponent("a")
        let b = directory.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ScanModel(store: nil, resolution: CompressorResolution(installation: nil, customRejection: nil),
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
        case "$*" in
            --version) echo 'applesauce 0.5.30'; exit 0 ;;
            'compress --help') echo 'lzfse --verify --minimum-compression-ratio'; exit 0 ;;
        esac
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
        let installation = ToolInstallation(source: .custom(binary.path), capabilities:
            ToolCapabilities(version: nil, compressors: ["lzfse"], supportsVerify: true,
                             supportsLevel: false, supportsMinimumRatio: true, rawUsage: ""))
        let model = ScanModel(store: nil, resolution: CompressorResolution(installation: installation, customRejection: nil),
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
