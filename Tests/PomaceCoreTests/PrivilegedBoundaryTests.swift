import Foundation
import Testing
@testable import PomaceCore

@Suite("privileged operation boundary")
struct PrivilegedBoundaryTests {
    private func shell(_ arguments: [String]) -> Subprocess.Output {
        Subprocess.capture("/bin/bash", AdministratorAccess.boundaryArguments(arguments))
    }

    @Test(arguments: ["accepted", "owner", "group", "world", "acl", "symlink", "outside", "directory", "hardlink"])
    func directoryChain(kind: String) throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var file = parent.appendingPathComponent("file")
        try Data([65]).write(to: file)
        var owner = getuid()
        if kind == "owner" { owner += 1 }
        if kind == "group" || kind == "world" {
            try FileManager.default.setAttributes([.posixPermissions: kind == "group" ? 0o720 : 0o702], ofItemAtPath: parent.path)
        }
        if kind == "acl" {
            let added = Subprocess.capture("/bin/chmod", ["+a", "everyone allow add_file", parent.path])
            #expect(added.succeeded, "\(added.combined)")
        }
        defer { _ = Subprocess.capture("/bin/chmod", ["-N", parent.path]) }
        if kind == "symlink" {
            let link = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent)
            file = link.appendingPathComponent("file")
        }
        let outside = root.appendingPathExtension("outside")
        defer { try? FileManager.default.removeItem(at: outside) }
        if kind == "outside" {
            try Data([65]).write(to: outside)
            file = outside
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
        if kind == "directory" {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        }
        if kind == "hardlink" { try FileManager.default.linkItem(at: file, to: parent.appendingPathComponent("other")) }
        let result = shell(["validate", root.path, String(owner), root.path, "--", file.path])
        #expect(result.succeeded == (kind == "accepted"), "\(result.combined)")
        if kind != "accepted" { #expect(result.combined.contains("only administrators can change")) }
    }

    @Test func boundaryLaunchIgnoresInheritedStartupFile() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file")
        try Data([65]).write(to: file)
        let startup = root.appendingPathComponent("startup")
        let marker = root.appendingPathComponent("sourced")
        // A marker proves whether the inherited startup file was sourced.
        let script = "printf compromised > '\(marker.path)'"
        try script.write(to: startup, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = AdministratorAccess.boundaryArguments(["validate", root.path, String(getuid()), root.path, "--", file.path])
        process.environment = ["BASH_ENV": startup.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func probeRefusesBytesChangedDuringCapabilityCheck() throws {
        let binary = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: binary) }
        try #"""
        #!/bin/sh
        if [ "$1" = compress ]; then
            printf '#!/bin/sh\necho replacement\n' > "$0"
            echo 'lzfse --verify --minimum-compression-ratio'
        else
            echo 'applesauce 0.5.30'
        fi
        """#.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let before = try #require(CompressorTool.sha256(at: binary.path))
        let installation = CompressorTool.probe(.custom(binary.path))
        #expect(CompressorTool.sha256(at: binary.path) != before)
        #expect(!installation.capabilities.isUsable)
    }

    @Test(arguments: [false, true])
    func samePathChangedBeforeAuthorization(bundled: Bool) async throws {
        let binary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: binary) }
        let text = "#!/bin/sh\necho 'lzfse zlib --verify --minimum-compression-ratio'\n"
        try text.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let source: ToolSource = bundled ? .bundled(binary.path) : .custom(binary.path)
        let confirmed = CompressorTool.probe(source)
        #expect(confirmed.sha256 != nil)
        try (text + "# replacement\n").write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        #expect(CompressorTool.sha256(at: binary.path) != confirmed.sha256)
        let executor = CompressionExecutor(isAdministrator: true) { _, _ in
            Issue.record("Changed bytes reached authorization/execution")
            return .authorizationCancelled
        }
        var failure: CompressionEngineError?
        for await event in CompressionEngine.run(operation: .compress, paths: [], root: "/Applications",
                installation: confirmed, plan: CompressionPolicy.plan(), executor: executor,
                resolveCompressor: { _ in CompressorResolution(installation: CompressorTool.probe(source), customRejection: nil) }) {
            if case .failed(let error) = event { failure = error }
        }
        #expect(failure == .compressorChanged(confirmed: binary.path, resolved: binary.path))
    }

    @Test(arguments: ["before-copy", "between-batches"])
    func replacementRefused(timing: String) throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("compressor")
        let file = root.appendingPathComponent("file")
        try Data([65]).write(to: file)
        try "#!/bin/sh\nprintf 'checked-copy'\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let hash = try #require(CompressorTool.sha256(at: binary.path))
        let replacement = "#!/bin/sh\nprintf 'UNCONFIRMED'\n"
        if timing == "before-copy" {
            try replacement.write(to: binary, atomically: true, encoding: .utf8)
            let refused = shell(["prepare", binary.path, hash])
            #expect(!refused.succeeded)
            #expect(!refused.combined.contains("UNCONFIRMED"))
            return
        }
        let prepared = shell(["prepare", binary.path, hash])
        #expect(prepared.succeeded, "\(prepared.combined)")
        let directory = prepared.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(directory.hasPrefix("/private/tmp/pomace-"))
        defer { _ = shell(["cleanup", directory]) }
        #expect(CompressorTool.sha256(at: directory + "/compressor") == hash)
        let args = ["run", directory, binary.path, hash, root.path, String(getuid()), root.path, "--", file.path]
        let first = shell(args)
        #expect(first.succeeded && first.stdout == "checked-copy")
        try replacement.write(to: binary, atomically: true, encoding: .utf8)
        let second = shell(args)
        #expect(!second.succeeded)
        #expect(!second.combined.contains("UNCONFIRMED"))
        #expect(CompressorTool.sha256(at: directory + "/compressor") == hash)
    }
}
