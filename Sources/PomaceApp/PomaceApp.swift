import SwiftUI
import AppKit
import PomaceCore

struct PomaceApp: App {
    @State private var model = ScanModel()
    @AppStorage("menuBarEnabled") private var menuBarEnabled = false
    @ObservedObject private var updates = Main.updates!

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
                        Button(AppStrings.addFolder, systemImage: "folder.badge.plus") { addFolder() }
                            .help(AppStrings.addFolderTooltip)
                    }
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(AppStrings.about) { showAbout() }
                Button(AppStrings.checkUpdates) { updates.checkForUpdates() }
                    .disabled(!updates.canCheckForUpdates)
            }
            CommandGroup(after: .newItem) {
                Button(AppStrings.addFolderMenu) { addFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button(AppStrings.rescan) { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.selectedPath == nil)
            }
        }

        Settings {
            TabView {
                GeneralSettingsView(updates: updates)
                    .tabItem { Label(AppStrings.general, systemImage: "gearshape") }
                AdvancedSettingsView(model: model)
                    .tabItem { Label(AppStrings.advanced, systemImage: "slider.horizontal.3") }
            }
        }

        MenuBarExtra(isInserted: $menuBarEnabled) {
            Button(AppStrings.openApp, action: bringToFront)
            Divider()
            if let path = model.selectedPath {
                Text((path as NSString).lastPathComponent)
            } else {
                Text(AppStrings.noFolderSelected)
            }
            Button(AppStrings.rescan) { model.rescan() }
                .disabled(model.selectedPath == nil)
            Button(AppStrings.sweepNow) { model.sweepNow() }
                .disabled(model.selectedPath == nil || !model.toolReady || model.isSweeping)
            Divider()
            Button(AppStrings.quit) { NSApp.terminate(nil) }
        } label: {
            Label(AppStrings.appName, systemImage: "internaldrive")
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
        panel.prompt = AppStrings.scan
        panel.message = AppStrings.scanHelp
        if panel.runModal() == .OK, let url = panel.url {
            model.add(path: url.path)
        }
    }

    private func showAbout() {
        let source = "https://github.com/Dr-Emann/applesauce"
        let credits = NSMutableAttributedString(string: AppStrings.credits(source))
        credits.addAttribute(.link, value: URL(string: source)!,
                             range: (credits.string as NSString).range(of: source))
        NSApp.orderFrontStandardAboutPanel(options: [NSApplication.AboutPanelOptionKey.credits: credits])
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}
