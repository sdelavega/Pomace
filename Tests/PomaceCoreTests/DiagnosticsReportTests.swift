import Foundation
import Testing
@testable import PomaceCore

@Suite("Diagnostics report")
struct DiagnosticsReportTests {
    private func input(source: ToolSource = .bundled("/Applications/Pomace.app/Contents/Helpers/applesauce")) -> DiagnosticsInput {
        let caps = ToolCapabilities(version: ToolVersion(major: 0, minor: 5, patch: 30), compressors: ["lzfse"],
                                    supportsVerify: true, supportsLevel: false, supportsMinimumRatio: true, rawUsage: "")
        return DiagnosticsInput(appVersion: "1.1.0", build: "10100", osVersion: "macOS test", architecture: "arm64",
            compressor: CompressorResolution(installation: ToolInstallation(source: source, capabilities: caps), customRejection: nil),
            agentRegistered: true, logLines: ["NOTE /Users/alex/Secret Plans/über/movie.mov", "alex@alex-mbp"],
            crashReports: [("Pomace-alex.ips", #"{"path":"\/Users\/alex\/Secret Plans\/über\/movie.mov","host":"alex-mbp"}"#)],
            scannedRoots: [URL(fileURLWithPath: "/Users/alex/Secret Plans")],
            homeDirectory: URL(fileURLWithPath: "/Users/alex"), userName: "alex", hostName: "alex-mbp")
    }

    @Test func reportListsCompressorSource() {
        let report = DiagnosticsReport.render(input())
        #expect(report.contains("Compressor: bundled") && report.contains("0.5.30"))
        #expect(report.contains("1.1.0") && report.contains("10100"))
        #expect(report.contains("macOS test") && report.contains("arm64"))
        #expect(report.contains("Agent registered: yes"))
        #expect(DiagnosticsReport.render(input(source: .custom("/Users/alex/bin/applesauce"))).contains("Compressor: custom"))
    }

    @Test func everyReportSectionIsRedacted() {
        var data = input(source: .custom("/Users/alex/Secret Plans/applesauce"))
        data.appVersion = "alex"
        data.build = "alex-mbp"
        data.osVersion = "/Volumes/Alex's Drive/test"
        data.architecture = "/private/var/folders/ab/xyz/T/test"
        let report = DiagnosticsReport.render(data)
        #expect(report.contains("Pomace diagnostics") && report.contains("Pomace-<user>.ips"))
        #expect(report.contains("<folder-1>") && report.contains("<host>"))
        for secret in ["alex", "Secret", "über", "movie.mov", "Alex's", "xyz"] { #expect(!report.contains(secret)) }
    }

    @Test func missingCompressorAndEmptySectionsAreHonest() {
        var data = input()
        data.compressor = CompressorResolution(installation: nil, customRejection: .notFound)
        data.agentRegistered = false
        data.logLines = []
        data.crashReports = []
        let report = DiagnosticsReport.render(data)
        #expect(report.contains("Compressor: unavailable") && report.contains("Agent registered: no"))
        #expect(report.contains("No log lines available") && report.contains("No crash reports available"))
        #expect(report.contains("notFound"))
    }

    @Test func issueURLTruncates() throws {
        let body = String(repeating: "diagnostic line 😀 & /?\n", count: 2500)
        #expect(body.utf8.count > 50_000)
        let url = DiagnosticsReport.githubIssueURL(body: body)
        #expect(url.absoluteString.count <= 7500)
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let report = try #require(items.first { $0.name == "body" }?.value)
        #expect(report.contains("attach the saved report"))
        #expect(report.contains("diagnostic line"))
        #expect(!report.contains("�"))
    }

    @Test func issueURLPreservesSmallBody() throws {
        let body = "Report: &body=private # + ? 😀\nnext"
        let url = DiagnosticsReport.githubIssueURL(body: body)
        #expect(url.scheme == "https" && url.host == "github.com" && url.path == "/sdelavega/Pomace/issues/new")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.count == 2)
        #expect(items.first { $0.name == "title" }?.value == "")
        #expect(items.first { $0.name == "body" }?.value == body)
    }

    @Test func customURLBudgetIsHonored() throws {
        let url = DiagnosticsReport.githubIssueURL(body: String(repeating: "界", count: 500), maxURLLength: 300)
        #expect(url.absoluteString.count <= 300)
        let body = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        #expect(body.contains("attach the saved report"))
    }

    @Test(arguments: [false, true]) func logTailHandlesChunksAndEmptyFiles(finalNewline: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mutations.log")
        try "".write(to: url, atomically: true, encoding: .utf8)
        #expect(DiagnosticsFiles.logLines(at: url).isEmpty)
        let lines = (0..<510).map { "\($0):" + String(repeating: "界", count: 400) }
        let text = lines.joined(separator: "\n") + (finalNewline ? "\n" : "")
        #expect(text.utf8.count > 128 * 1024)
        try text.write(to: url, atomically: true, encoding: .utf8)
        #expect(DiagnosticsFiles.logLines(at: url) == Array(lines.suffix(500)))
        #expect(DiagnosticsFiles.logLines(at: url, limit: 0).isEmpty)
    }

    @Test func fileCollectionUsesOnlyRecentPomaceCrashesAndLogTail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("mutations.log")
        let lines = (0..<510).map { "line-\($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: log, atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for (name, age) in [("Pomace-alex.ips", 1.0), ("Pomace-old.ips", 31.0), ("Other.ips", 1.0), ("Pomace.txt", 1.0)] {
            let url = directory.appendingPathComponent(name)
            try #"{"path":"\/Users\/alex\/Secret Plans\/über.mov"}"#.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86400)], ofItemAtPath: url.path)
        }
        let ignoredDirectory = directory.appendingPathComponent("Pomace-directory.ips")
        try FileManager.default.createDirectory(at: ignoredDirectory, withIntermediateDirectories: false)
        let tail = DiagnosticsFiles.logLines(at: log)
        #expect(tail.count == 500 && tail.first == "line-10" && tail.last == "line-509")
        let crashes = DiagnosticsFiles.crashReports(in: directory, now: now)
        #expect(crashes.count == 1 && crashes.first?.name == "Pomace-alex.ips")
        #expect(crashes.first?.contents.contains("alex") == true)
        #expect(DiagnosticsFiles.logLines(at: directory.appendingPathComponent("missing")).isEmpty)
        #expect(DiagnosticsFiles.crashReports(in: directory.appendingPathComponent("missing"), now: now).isEmpty)
    }
}
