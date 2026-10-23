import Foundation
import Testing
import PomaceCore
@testable import PomaceApp

@Suite("Diagnostics context")
struct DiagnosticsContextTests {
    @Test @MainActor func historyIncludesLastTwentyRunsAcrossFolders() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(url: directory.appendingPathComponent("history.sqlite"))
        for n in 0..<25 {
            try store.recordSweep(path: "/Users/alex/Plans-\(n % 2)", startedAt: Date(timeIntervalSince1970: Double(n)),
                                  duration: 2, filesCompressed: n, filesFailed: 0, bytesReclaimed: 1024,
                                  deferral: nil, error: nil, cancelled: false)
        }
        #expect(try store.sweepHistory(path: "/Users/alex/Plans-0", limit: 30).count == 13)
        let log = MutationLog(url: directory.appendingPathComponent("mutations.log"))
        log.note("synthetic alex log")
        let model = ScanModel(store: store, log: log)
        model.watchedPaths = ["/Users/alex/Watched"]
        model.selectedPath = "/Users/alex/Selected"
        let context = model.diagnosticsContext()
        #expect(context.history.count == 20)
        #expect(context.history.first?.contains("1970-01-01T00:00:24Z") == true)
        #expect(context.history.last?.contains("1970-01-01T00:00:05Z") == true)
        #expect(context.history.first?.contains("compressed=24") == true)
        #expect(context.history.first?.contains("reclaimed=1024") == true)
        let redacted = Redactor(homeDirectory: URL(fileURLWithPath: "/Users/alex"), userName: "alex", hostName: "alex-mbp", roots: context.roots)
            .redact(context.history.joined(separator: "\n"))
        #expect(redacted.contains("compressed=24") && redacted.contains("reclaimed=1024"))
        #expect(!redacted.contains("Plans-"))
        #expect(context.roots.map(\.path) == ["/Users/alex/Plans-0", "/Users/alex/Plans-1", "/Users/alex/Selected", "/Users/alex/Watched"])
        #expect(log.url == directory.appendingPathComponent("mutations.log"))
        #expect(DiagnosticsFiles.logLines(at: log.url).first?.contains("synthetic alex log") == true)
    }

    @Test(arguments: [false, true]) @MainActor
    func forgottenRootsHideLogAndCrashContents(evicted: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = "/Users/alex/Documents/Secret Plans"
        let privatePath = root + "/payroll.txt"
        let store = try Store(url: directory.appendingPathComponent("history.sqlite"))
        if evicted {
            for n in 0..<21 {
                try store.recordSweep(path: n == 0 ? root : "/Users/alex/Current", startedAt: Date(timeIntervalSince1970: Double(n)),
                                      duration: 1, filesCompressed: 1, filesFailed: 0, bytesReclaimed: 1,
                                      deferral: nil, error: nil, cancelled: false)
            }
        }
        let log = MutationLog(url: directory.appendingPathComponent("mutations.log"))
        log.note("batch first=\(privatePath)")
        let model = ScanModel(store: store, log: log)
        model.watchedPaths = [root]
        model.watchedPaths.removeAll()
        model.selectedPath = nil
        let context = model.diagnosticsContext()
        #expect(!context.roots.map(\.path).contains(root))
        #expect(context.history.count == (evicted ? 20 : 0))
        let lines = DiagnosticsFiles.logLines(at: log.url)
        #expect(lines.contains { $0.contains(privatePath) })
        let crash = #"{"path":"/Users/alex/Documents/Secret Plans/payroll.txt","external":"/Volumes/Old Disk/Secret Plans/payroll.txt","temporary":"/private/var/folders/ab/secret/T/payroll.txt"}"#
        let report = DiagnosticsReport.render(DiagnosticsInput(
            appVersion: "test", build: "1", osVersion: "test", architecture: "test",
            compressor: model.resolution, agentRegistered: false, logLines: lines + context.history,
            crashReports: [(name: "Pomace.ips", contents: crash)], scannedRoots: context.roots,
            homeDirectory: URL(fileURLWithPath: "/Users/alex"), userName: "alex", hostName: "alex-mbp"))
        #expect(report.contains("~/Documents/<path>"))
        #expect(!report.contains("payroll") && !report.contains("Secret Plans"))
        #expect(!report.contains("Old Disk") && !report.contains("/secret/"))
    }

    @Test func historyRendererKeepsDiagnosticFieldsInEnglish() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try Store(url: directory.appendingPathComponent("history.sqlite"))
        try store.recordSweep(path: "/Users/alex/Plans", startedAt: Date(timeIntervalSince1970: 0),
                              duration: 2.5, filesCompressed: 3, filesFailed: 1, bytesReclaimed: 2048,
                              deferral: .onBattery, error: "synthetic failure", cancelled: true)
        let run = try #require(store.sweepHistory(path: "/Users/alex/Plans").first)
        let text = CoreText.diagnosticsHistory(run)
        for field in ["1970-01-01T00:00:00Z", "compressed=3", "failed=1", "reclaimed=2048", "duration=2.5",
                      "onBattery", "synthetic failure", "cancelled=true"] { #expect(text.contains(field)) }
    }
}
