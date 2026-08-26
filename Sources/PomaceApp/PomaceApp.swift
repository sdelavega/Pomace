import SwiftUI
import AppKit
import PomaceCore

struct PomaceApp: App {
    @State private var model = ScanModel()

    /// `--scan <path>` opens straight onto a folder without the panel. Used by the test
    /// harness, and the same argument-dispatch shape the headless `--sweep` mode needs in M3.
    private static var launchScanPath: String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--scan"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 940, minHeight: 560)
                .task {
                    SweepNotifier.requestAuthorizationIfNeeded()
                    model.refreshServiceStatus()
                    if let p = Self.launchScanPath {
                        model.add(path: p)
                    } else {
                        model.restoreSelection()
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { addFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Rescan") { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.selectedPath == nil)
            }
        }
    }

    private func addFolder() {
        // NSOpenPanel is also how the user grants access to a TCC-protected location:
        // choosing the folder here is the consent gesture, so this is deliberately the
        // only way a directory enters the app.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to scan. Pomace only reads it — nothing is modified."
        if panel.runModal() == .OK, let url = panel.url {
            model.add(path: url.path)
        }
    }
}
