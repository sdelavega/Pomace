import Foundation
import Testing
@testable import PomaceCore

@Suite("compressor resolution")
struct CompressorResolutionTests {
    private struct Fixture {
        let directory: URL
        let bundled: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PomaceResolution-\(UUID())").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            bundled = directory.appendingPathComponent("bundled")
            try Self.writeFake(at: bundled)
        }

        func custom(verified: Bool = true) throws -> URL {
            let url = directory.appendingPathComponent("custom")
            try Self.writeFake(at: url, verified: verified)
            return url
        }

        static func writeFake(at url: URL, verified: Bool = true) throws {
            try """
            #!/bin/sh
            case "$*" in
                --version) echo 'applesauce 0.5.30' ;;
                'compress --help') echo 'lzfse \(verified ? "--verify --minimum-compression-ratio" : "")' ;;
                *) touch "$0.invoked" ;;
            esac
            """.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        func resolve(_ path: String? = nil, signature: Bool = true) -> CompressorResolution {
            CompressorTool.resolve(customPath: path, bundledURL: bundled, signatureIsValid: { _ in signature })
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    @Test func customUsableWins() throws {
        let f = try Fixture(); defer { f.remove() }
        let p = try f.custom().path
        #expect(FileManager.default.isExecutableFile(atPath: p))
        #expect(CompressorTool.probe(.custom(p)).capabilities.isUsable)
        let r = f.resolve(p)
        #expect(r.installation?.source == .custom(p))
        #expect(r.customRejection == nil)
    }

    @Test func customWithoutVerifyFallsBack() throws {
        let f = try Fixture(); defer { f.remove() }
        let p = try f.custom(verified: false).path
        let caps = CompressorTool.probe(.custom(p)).capabilities
        #expect(caps.compressors.contains("lzfse"))
        #expect(!caps.supportsVerify && !caps.supportsMinimumRatio)
        let r = f.resolve(p)
        #expect(r.installation?.source == .bundled(f.bundled.path))
        #expect(r.customRejection == .missingCapabilities([.verify, .minimumRatio]))
    }

    @Test func customDeletedAfterChoiceFallsBack() throws {
        let f = try Fixture(); defer { f.remove() }
        let url = try f.custom()
        #expect(f.resolve(url.path).installation?.source == .custom(url.path))
        try FileManager.default.removeItem(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let r = f.resolve(url.path)
        #expect(r.customRejection == .notFound)
        #expect(r.installation?.source == .bundled(f.bundled.path))
    }

    @Test func customRelativePathRejected() throws {
        let f = try Fixture(); defer { f.remove() }
        let r = f.resolve("relative/applesauce")
        #expect(r.customRejection == .relativePath)
        #expect(r.installation?.source == .bundled(f.bundled.path))
    }

    @Test func customSymlinkToShellRejected() throws {
        let f = try Fixture(); defer { f.remove() }
        let link = f.directory.appendingPathComponent("shell")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/bin/sh")
        #expect(link.resolvingSymlinksInPath().path == "/bin/sh")
        let r = f.resolve(link.path)
        #expect(r.customRejection == .missingCapabilities([.lzfse, .verify, .minimumRatio]))
        #expect(r.installation?.source == .bundled(f.bundled.path))
    }

    @Test func bundledBadSignatureUnavailable() throws {
        let f = try Fixture(); defer { f.remove() }
        #expect(f.resolve().installation?.source == .bundled(f.bundled.path))
        let r = f.resolve(signature: false)
        #expect(r.installation == nil)
        #expect(r.customRejection == nil)
    }

    @Test func customMustBeRegularAndExecutable() throws {
        let f = try Fixture(); defer { f.remove() }
        let url = try f.custom()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(!FileManager.default.isExecutableFile(atPath: url.path))
        let nonExecutable = f.resolve(url.path)
        #expect(nonExecutable.customRejection == .notExecutable)
        #expect(nonExecutable.installation?.source == .bundled(f.bundled.path))
        #expect(FileManager.default.isExecutableFile(atPath: f.directory.path))
        let directory = f.resolve(f.directory.path)
        #expect(directory.customRejection == .notRegularFile)
        #expect(directory.installation?.source == .bundled(f.bundled.path))
    }

    @Test func customSymlinkResolvesToCheckedFile() throws {
        let f = try Fixture(); defer { f.remove() }
        let url = try f.custom()
        let link = f.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        #expect(link.path != url.path)
        let r = f.resolve(link.path)
        #expect(r.installation?.source == .custom(url.path))
        #expect(r.customRejection == nil)
    }

    @Test func bundledMustBeUsable() throws {
        let f = try Fixture(); defer { f.remove() }
        #expect(f.resolve().installation != nil)
        try Fixture.writeFake(at: f.bundled, verified: false)
        #expect(f.resolve().installation == nil)
        try FileManager.default.removeItem(at: f.bundled)
        #expect(f.resolve().installation == nil)
    }

    @Test func engineRechecksChosenCustom() async throws {
        let f = try Fixture(); defer { f.remove() }
        let url = try f.custom()
        let installation = try #require(f.resolve(url.path).installation)
        #expect(installation.source == .custom(url.path))
        #expect(CompressorTool.bundledURL == nil)
        try Fixture.writeFake(at: url, verified: false)
        let file = f.directory.appendingPathComponent("file.txt")
        try Data(repeating: 65, count: 4096).write(to: file)
        #expect(!CompressorTool.probe(.custom(url.path)).capabilities.isUsable)
        var refused = false
        for await event in CompressionEngine.run(operation: .compress, paths: [file.path],
                root: f.directory.path, installation: installation, plan: CompressionPolicy.plan()) {
            if case .failed(let message) = event { refused = message.contains("compressor") }
        }
        #expect(refused)
        #expect(!FileManager.default.fileExists(atPath: url.path + ".invoked"))
    }

    @Test("only standard runs may fall back after the confirmed compressor changes",
          arguments: [true, false], [true, false])
    func engineFallbackHonorsConfirmation(deleted: Bool, isAdministrator: Bool) async throws {
        let f = try Fixture(); defer { f.remove() }
        let url = try f.custom()
        let confirmed = try #require(f.resolve(url.path).installation)
        #expect(confirmed.source == .custom(url.path))
        #expect(confirmed.capabilities.isUsable)
        if deleted {
            try FileManager.default.removeItem(at: url)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        } else {
            try Fixture.writeFake(at: url, verified: false)
            #expect(!CompressorTool.probe(.custom(url.path)).capabilities.isUsable)
        }
        let resolution = f.resolve(url.path)
        let fallback = try #require(resolution.installation)
        #expect(resolution.customRejection == (deleted ? .notFound : .missingCapabilities([.verify, .minimumRatio])))
        #expect(fallback.source == .bundled(f.bundled.path))
        #expect(fallback.path != confirmed.path)
        #expect(fallback.capabilities.isUsable)
        let file = f.directory.appendingPathComponent("file.txt")
        try Data(repeating: 65, count: 4096).write(to: file)
        let metadata = try #require(FileInspector.inspect(file.path))
        #expect(metadata.isRegularFile && !metadata.isCompressed)
        #expect(!SafetyRules().isExcluded(metadata, volume: VolumeContext.probe(path: f.directory.path), depth: .thorough))
        let marker = f.bundled.path + ".invoked"
        #expect(!FileManager.default.fileExists(atPath: marker))
        let executor = CompressionExecutor(isAdministrator: isAdministrator) { path, args in
            // This fake executor never requests authorization, even for the elevated case.
            .completed(Subprocess.capture(path, args))
        }
        var failures: [String] = []
        var started = false
        var outcome: CompressionOutcome?
        let root = isAdministrator ? "/Applications" : f.directory.path
        #expect(!isAdministrator || AdministratorAccess.supports(root: root))
        for await event in CompressionEngine.run(operation: .compress, paths: [file.path], root: root,
                installation: confirmed, plan: CompressionPolicy.plan(), executor: executor,
                resolveCompressor: { [bundled = f.bundled] path in
                    CompressorTool.resolve(customPath: path, bundledURL: bundled, signatureIsValid: { _ in true })
                }) {
            switch event {
            case .failed(let message): failures.append(message)
            case .started, .progress: started = true
            case .finished(let result): outcome = result
            }
        }
        if isAdministrator {
            let failure = try #require(failures.first)
            #expect(failures.count == 1)
            #expect(failure.contains("The compressor changed after you confirmed"))
            #expect(failure.contains(confirmed.path))
            #expect(failure.contains(fallback.path))
            #expect(!started)
            #expect(outcome == nil)
            #expect(!FileManager.default.fileExists(atPath: marker))
        } else {
            #expect(failures.isEmpty)
            #expect(started)
            #expect(try #require(outcome).filesAttempted == 1)
            #expect(FileManager.default.fileExists(atPath: marker))
        }
        #expect(!FileManager.default.fileExists(atPath: confirmed.path + ".invoked"))
    }

    @Test func compressArgumentsAlwaysVerify() {
        for mode in CompressionMode.allCases {
            let plan = CompressionPolicy.plan(mode: mode)
            #expect(plan.arguments.contains("--verify"))
        }
    }
}
