import Foundation
import Testing
@testable import PomaceCore

@Suite("per-run compressor resolution")
struct RunResolutionTests {
    @Test func maximumSavingsRebuildsForLZFSEOnlyReplacement() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("compressor")
        let file = root.appendingPathComponent("file.txt")
        try Data(repeating: 65, count: 4096).write(to: file)
        func write(_ algorithms: String) throws {
            try "#!/bin/sh\necho 'applesauce 0.5.30 \(algorithms) --verify --minimum-compression-ratio'\n".write(to: binary, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        }
        try write("lzfse zlib")
        let old = try #require(CompressorTool.resolve(customPath: binary.path, bundledURL: nil).installation)
        let plan = CompressionPolicy.plan(mode: .maximumSavings, capabilities: old.capabilities)
        #expect(plan.arguments.contains("zlib"))
        try write("lzfse")
        let replacement = try #require(CompressorTool.resolve(customPath: binary.path, bundledURL: nil).installation)
        #expect(!replacement.capabilities.compressors.contains("zlib"))
        let executor = CompressionExecutor(isAdministrator: false) { _, args in
            #expect(args.contains("lzfse") && !args.contains("zlib"))
            #expect(args.contains("--verify") && args.contains("0.9900"))
            return .completed(Subprocess.Output(stdout: "", stderr: "", code: 0))
        }
        var resolutions = 0
        var final: CompressionOutcome?
        for await event in CompressionEngine.run(operation: .compress, paths: [file.path], root: root.path,
                installation: old, plan: plan, executor: executor) {
            switch event {
            case .resolved(let resolution):
                resolutions += 1
                #expect(resolution.installation?.capabilities.compressors == ["lzfse"])
            case .finished(let outcome): final = outcome
            default: break
            }
        }
        #expect(resolutions == 1)
        #expect(final?.filesAttempted == 1)
        #expect(final?.settings.compressor == "lzfse")
    }
}
