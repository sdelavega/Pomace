import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PomaceCore

struct ReportProblemView: View {
    let model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var report: String?
    @State private var saveFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AppStrings.reportProblem).font(.title2)
            Text(AppStrings.reportExplanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let report {
                TextEditor(text: .constant(report))
                    .font(.system(.body, design: .monospaced))
                    .disabled(true)
                    .accessibilityLabel(AppStrings.reportContents)
            } else {
                ProgressView(AppStrings.reportPreparing)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Button(AppStrings.reportCopy) {
                    guard let report else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                Button(AppStrings.reportSave, action: save)
                Spacer()
                Button(AppStrings.reportOpenIssue) {
                    guard let report else { return }
                    NSWorkspace.shared.open(DiagnosticsReport.githubIssueURL(body: report))
                }
            }
            .disabled(report == nil)
        }
        .padding(24)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 480, idealHeight: 600)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(AppStrings.done) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .alert(AppStrings.reportSaveFailed, isPresented: $saveFailed) {
            Button(AppStrings.done, role: .cancel) {}
        }
        .task { await prepareReport() }
    }

    private func prepareReport() async {
        let context = model.diagnosticsContext()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logURL = model.log.url
        let crashDirectory = home.appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        let input = DiagnosticsInput(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
            compressor: model.resolution, agentRegistered: SweepService.status.isActive,
            logLines: context.history, crashReports: [], scannedRoots: context.roots,
            homeDirectory: home, userName: NSUserName(), hostName: ProcessInfo.processInfo.hostName)
        // Collection starts only when the user opens this sheet. No export happens here.
        report = await Task.detached(priority: .userInitiated) {
            var collected = input
            collected.logLines = DiagnosticsFiles.logLines(at: logURL) + input.logLines
            collected.crashReports = DiagnosticsFiles.crashReports(in: crashDirectory)
            return DiagnosticsReport.render(collected)
        }.value
    }

    private func save() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let date = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
        panel.nameFieldStringValue = "Pomace-report-\(date).txt" // l10n-exempt: Diagnostic report filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try report.write(to: url, atomically: true, encoding: .utf8) }
        catch { saveFailed = true }
    }
}
