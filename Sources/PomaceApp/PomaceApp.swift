import SwiftUI
import AppKit
import PomaceCore

struct PomaceApp: App {
    @NSApplicationDelegateAdaptor(UpdateTerminationDelegate.self) private var terminationDelegate
    @State private var model = makeModel()

    private static func makeModel() -> ScanModel {
        #if DEBUG
        if let path = Main.uiTestFixturePath {
            let model = ScanModel(store: nil, log: MutationLog(url: URL(fileURLWithPath: path).appendingPathExtension("log")))
            model.prepareUITestFixture(path)
            return model
        }
        #endif
        return ScanModel()
    }
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
                    #if DEBUG
                    if Main.uiTestFixturePath != nil { return }
                    #endif
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
            CommandGroup(replacing: .help) {
                Button(AppStrings.reportProblem) { model.showingReportProblem = true }
            }
            CommandGroup(after: .newItem) {
                Button(AppStrings.addFolderMenu) { addFolder() }
                    .keyboardShortcut("o", modifiers: .command)
                Button(AppStrings.rescan) { model.rescan() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.selectedPath == nil || model.isRunning || model.isSweeping)
                Divider()
                Button(AppStrings.compress) { model.startCompress() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.compressibleCount == 0 || !model.toolReady || model.isRunning || model.isSweeping)
                Button(AppStrings.decompress) { model.requestDecompress() }
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(model.compressedCount == 0 || !model.toolReady || model.isRunning || model.isSweeping)
                Button(AppStrings.stop) {
                    if model.isRunning { model.cancelRun() } else { model.cancelScan() }
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled((!model.isRunning && !model.isScanning) || model.isStopping)
            }
            #if DEBUG
            if Main.uiTestFixturePath != nil {
                CommandMenu(AppStrings.state) {
                    Button(AppStrings.decompress) { model.requestDecompress() }
                    Button(AppStrings.authorizeAdministrator) { model.confirmingAdministrator = true }
                }
            }
            #endif
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
        let translating = "https://github.com/sdelavega/Pomace/blob/main/docs/TRANSLATING.md"
        credits.addAttribute(.link, value: URL(string: translating)!,
                             range: (credits.string as NSString).range(of: translating))
        NSApp.orderFrontStandardAboutPanel(options: [NSApplication.AboutPanelOptionKey.credits: credits])
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}
