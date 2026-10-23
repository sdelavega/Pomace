import Foundation
import Testing
@testable import PomaceCore

@Suite("administrator compression")
struct AdministratorAccessTests {
    @Test("scope checks use path boundaries and resolve symlinks")
    func scope() throws {
        for root in ["/Applications", "/Applications/Example.app", "/opt/homebrew/Cellar/tool", "/usr/local/Cellar"] {
            #expect(AdministratorAccess.supports(root: root))
        }
        for root in ["/", "/System/Applications", "/usr/locality", "/ApplicationsOther", "/opt/homebrew/../../System"] {
            #expect(!AdministratorAccess.supports(root: root))
        }
        #expect(AdministratorAccess.permits(path: "/Applications/A.app/Contents/file", root: "/Applications/A.app"))
        #expect(!AdministratorAccess.permits(path: "/Applications/B.app/file", root: "/Applications/A.app"))
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceAdminLink-\(UUID())")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/System")
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(!AdministratorAccess.supports(root: link.path))
    }

    @Test("the actual authorization script compiles without prompting")
    func scriptCompiles() throws {
        let script = try #require(NSAppleScript(source: AdministratorAccess.script))
        var error: NSDictionary?
        let compiled = script.compileAndReturnError(&error)
        #expect(compiled, "\(error ?? [:])")
    }

    @Test("arguments remain literal through AppleScript and shell quoting")
    func quoting() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceNoInjection-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        // Execute the production argv/quoting logic WITHOUT elevation. No test requests
        // an administrator password or executes any command as root.
        let script = AdministratorAccess.script.replacingOccurrences(
            of: " with prompt authorizationPrompt with administrator privileges",
            with: "")
        #expect(script != AdministratorAccess.script)
        let values = ["", "with spaces", "single'quote", "double\"quote", "back\\slash", "line\nbreak",
                      "$(touch \(marker.path))", "; touch \(marker.path);", "--verify"]
        let output = Subprocess.capture("/usr/bin/osascript", ["-e", script, "--", "Test prompt", "A selected path is no longer a regular file.", "/usr/bin/printf", "%s|"] + values)
        #expect(output.succeeded, "\(output.stderr)")
        #expect(output.stdout.replacingOccurrences(of: "\r", with: "\n") == values.map { $0 + "|" }.joined() + "\n")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("directories and symlinks cannot be handed to the elevated file invocation")
    func fileChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceAdminFileCheck-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("file")
        try Data([65]).write(to: file)
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let script = AdministratorAccess.script.replacingOccurrences(
            of: " with prompt authorizationPrompt with administrator privileges",
            with: "")
        #expect(script != AdministratorAccess.script)
        for path in [directory.path, link.path] {
            let output = Subprocess.capture("/usr/bin/osascript", ["-e", script, "--", "Test prompt", "A selected path is no longer a regular file.", "/usr/bin/printf", "%s", "--", path])
            #expect(!output.succeeded)
            #expect(output.stderr.contains("no longer a regular file"))
        }
        let output = Subprocess.capture("/usr/bin/osascript", ["-e", script, "--", "Test prompt", "A selected path is no longer a regular file.", "/usr/bin/printf", "%s", "--", file.path])
        #expect(output.succeeded)
    }

    @Test("only an actual authorization cancellation is treated as cancelled")
    func cancellationProtocol() {
        let cancelled = AdministratorAccess.interpret(Subprocess.Output(stdout: "",
            stderr: "execution error: POMACE_ADMIN_ERROR:-128:User canceled. (-128)", code: 1))
        guard case .authorizationCancelled = cancelled else {
            Issue.record("Cancellation was not recognized")
            return
        }
        let failed = AdministratorAccess.interpret(Subprocess.Output(stdout: "",
            stderr: "execution error: POMACE_ADMIN_ERROR:1:POMACE_ADMIN_ERROR:-128:tool error", code: 1))
        guard case .completed(let output) = failed else {
            Issue.record("A tool error was incorrectly treated as authorization cancellation")
            return
        }
        #expect(!output.succeeded)
    }

    @Test("elevated skips are not misclassified using the normal user's write permissions")
    func elevatedSkip() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceAdminReadonly-\(UUID())")
        try Data(repeating: 65, count: 4096).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)
        let elevated = CompressionEngine.classifySkip(path: file.path, operation: .compress, output: "", isAdministrator: true)
        #expect(elevated == .insufficientSaving)
        if geteuid() != 0 {
            let standard = CompressionEngine.classifySkip(path: file.path, operation: .compress, output: "")
            #expect(standard == .unwritable)
        }
    }

    @Test("a failed metadata probe is not treated as an absent resource fork")
    func metadataProbe() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceAdminMetadata-\(UUID())")
        #expect(!AdministratorAccess.canInspectResourceFork(at: file.path))
        try Data([65]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(AdministratorAccess.canInspectResourceFork(at: file.path))
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var arguments: [[String]] = []
        func record(_ args: [String]) { lock.lock(); defer { lock.unlock() }; arguments.append(args) }
        var all: [[String]] { lock.lock(); defer { lock.unlock() }; return arguments }
    }

    @Test("cancelled authorization retains a final outcome and attempts no files")
    func cancelledAuthorization() async throws {
        let calls = Calls()
        let executor = CompressionExecutor(isAdministrator: false) { _, args in
            calls.record(args)
            return .authorizationCancelled
        }
        let outcome = try await run(executor: executor)
        #expect(outcome.wasCancelled)
        #expect(outcome.filesAttempted == 0)
        #expect(outcome.bytesReclaimed == 0)
        #expect(calls.all.count == 1)
        #expect(calls.all.first?.contains("--verify") == true)
        #expect(calls.all.first?.contains("--") == true)
    }

    @Test("cancelling later authorization retains earlier completed batches")
    func laterAuthorizationCancellation() async throws {
        let calls = Calls()
        let executor = CompressionExecutor(isAdministrator: false) { _, args in
            calls.record(args)
            if calls.all.count == 1 {
                return .completed(Subprocess.Output(stdout: "", stderr: "", code: 0))
            }
            return .authorizationCancelled
        }
        let outcome = try await run(executor: executor)
        #expect(outcome.wasCancelled)
        #expect(outcome.filesAttempted == CompressionEngine.batchSize)
        #expect(outcome.bytesReclaimed == 0)
        #expect(calls.all.count == 2)
    }

    @Test("invocation errors are failures and do not retry subsequent batches")
    func commandFailure() async throws {
        let calls = Calls()
        let executor = CompressionExecutor(isAdministrator: false) { _, args in
            calls.record(args)
            return .completed(Subprocess.Output(stdout: "", stderr: "Permission denied", code: 1))
        }
        let outcome = try await run(executor: executor)
        #expect(outcome.filesAttempted == CompressionEngine.batchSize)
        #expect(outcome.realFailures.count == CompressionEngine.batchSize)
        #expect(outcome.skipped.isEmpty)
        #expect(outcome.bytesReclaimed == 0)
        #expect(calls.all.count == 1)
    }

    @Test("elevation outside the allowed locations is rejected before invocation")
    func unsupportedRoot() async throws {
        let calls = Calls()
        let executor = CompressionExecutor(isAdministrator: true) { _, args in
            calls.record(args)
            return .completed(Subprocess.Output(stdout: "", stderr: "", code: 0))
        }
        var refused = false
        for await event in CompressionEngine.run(operation: .compress, paths: [], root: NSTemporaryDirectory(),
                installation: installation, plan: CompressionPolicy.plan(), executor: executor) {
            if case .failed(let message) = event { refused = message == .administratorUnsupported }
        }
        #expect(refused)
        #expect(calls.all.isEmpty)
    }

    private var installation: ToolInstallation {
        ToolInstallation(source: .custom("/unused-test-compressor"), capabilities:
            ToolCapabilities(version: nil, compressors: ["lzfse"], supportsVerify: true,
                             supportsLevel: false, supportsMinimumRatio: true, rawUsage: ""))
    }

    private func run(executor: CompressionExecutor) async throws -> CompressionOutcome {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PomaceAdminTest-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("compressor")
        try """
        #!/bin/sh
        case "$*" in
            --version) echo 'applesauce 0.5.30' ;;
            'compress --help') echo 'lzfse --verify --minimum-compression-ratio' ;;
            *) exit 9 ;;
        esac
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let installation = try #require(CompressorTool.resolve(customPath: binary.path, bundledURL: nil).installation)
        var paths: [String] = []
        for index in 0...CompressionEngine.batchSize {
            let file = directory.appendingPathComponent("file-\(index).txt")
            try Data(repeating: 65, count: 4096).write(to: file)
            paths.append(file.path)
        }
        var final: CompressionOutcome?
        for await event in CompressionEngine.run(operation: .compress, paths: paths, root: directory.path,
                installation: installation, plan: CompressionPolicy.plan(), executor: executor) {
            if case .finished(let outcome) = event { final = outcome }
        }
        return try #require(final)
    }
}
