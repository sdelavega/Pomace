import SwiftUI
import AppKit
import PomaceCore

struct PomaceApp: App {
    @State private var model = ScanModel()
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false

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
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        Button("Add Folder", systemImage: "folder.badge.plus") { addFolder() }
                            .help("Add a folder or application bundle")
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

        MenuBarExtra(isInserted: $menuBarEnabled) {
            Button("Open Pomace", action: bringToFront)
            Divider()
            if let path = model.selectedPath {
                Text((path as NSString).lastPathComponent)
            } else {
                Text("No folder selected")
            }
            Button("Rescan") { model.rescan() }
                .disabled(model.selectedPath == nil)
            Button("Sweep Now") { model.sweepNow() }
                .disabled(model.selectedPath == nil || !model.toolReady || model.isSweeping)
            Divider()
            Button("Quit Pomace") { NSApp.terminate(nil) }
        } label: {
            Label("Pomace", systemImage: "internaldrive")
        }
        .menuBarExtraStyle(.menu)
    }

    private func addFolder() {
        // NSOpenPanel is also how the user grants access to a TCC-protected location:
        // choosing the folder here is the consent gesture, so this is deliberately the
        // only way a directory enters the app.
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder or application bundle to scan. Pomace only reads it — nothing is modified."
        if panel.runModal() == .OK, let url = panel.url {
            model.add(path: url.path)
        }
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}
