import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PomaceCore

enum MainFocusRegion: Int, CaseIterable {
    case sidebar, table, inspector
}

struct ContentView: View {
    @Bindable var model: ScanModel
    @FocusState private var focusedRegion: MainFocusRegion?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model, groups: sidebarGroups)
                .focused($focusedRegion, equals: .sidebar)
                .focusSection()
                .accessibilityLabel(AppStrings.folders)
                .background { AetherChrome() }
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Detail(model: model, focus: $focusedRegion)
                .inspector(isPresented: $model.showingInspector) {
                    InspectorView(model: model)
                        .aetherTheme()
                        .focusable()
                        .focused($focusedRegion, equals: .inspector)
                        .focusSection()
                        .accessibilityLabel(AppStrings.scheduleHelp)
                }
        }
        .onKeyPress(keys: [KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!))], phases: .down) { press in
            guard press.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
            let regions = MainFocusRegion.allCases.filter {
                ($0 != .inspector || model.showingInspector) && ($0 != .table || model.result != nil)
            }
            let current = regions.firstIndex(of: focusedRegion ?? .sidebar) ?? 0
            let step = press.modifiers.contains(.shift) ? regions.count - 1 : 1
            focusedRegion = regions[(current + step) % regions.count]
            return .handled
        }
        .onAppear { focusedRegion = .sidebar }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .background(NativeAccessibilityLabels(sidebarLabels: sidebarAccessibilityLabels,
                                               fileEntries: model.visibleEntries))
        .aetherTheme()
        .toolbarBackground(Aether.canvas, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        .navigationTitle(AppStrings.appName)
        .confirmationDialog(
            AppStrings.decompressQuestion(model.compressedCount),
            isPresented: $model.confirmingDecompress,
            titleVisibility: .visible
        ) {
            Button(AppStrings.decompressAction(model.compressedCount), role: .destructive) {
                model.confirmDecompress()
            }
            Button(AppStrings.cancel, role: .cancel) { model.confirmingDecompress = false }
                .keyboardShortcut(.defaultAction)
        } message: {
            // Returning files to their full on-disk size must never be a one-click surprise.
            Text(AppStrings.decompressExplanation)
        }
        .modifier(AdministratorConfirmation(model: model))
        .background(ConfirmationEscapeHandler(isPresented: model.confirmingDecompress || model.confirmingAdministrator) {
            if model.confirmingDecompress { model.confirmingDecompress = false }
            if model.confirmingAdministrator { model.cancelAdministrator() }
        })
        .sheet(isPresented: $model.showingSettings) {
            AdvancedSettingsView(model: model)
                .aetherTheme()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppStrings.done) { model.showingSettings = false }
                    }
                }
        }
        .sheet(isPresented: $model.showingReportProblem) {
            ReportProblemView(model: model)
        }
        .sheet(isPresented: $model.showingOnboarding) {
            OnboardingView(onContinue: model.dismissOnboarding)
                .aetherTheme()
        }
    }

    private var sidebarGroups: [SidebarGroup] {
        SidebarGroup.grouped(model.watchedPaths, isScheduled: model.isScheduled)
    }

    private var sidebarAccessibilityLabels: [String] {
        sidebarGroups.flatMap { $0.accessibilityLabels(scheduleSummary: model.folderSummary) }
    }
}

private struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            AetherBadge(text: AppStrings.onboardingGetStarted)
            Image(systemName: "internaldrive")
                .font(.system(size: 36, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Aether.accent)
                .padding(16)
                .background(Aether.well, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            Text(AppStrings.onboardingTitle).font(.system(.title, weight: .semibold))
            Text(AppStrings.onboardingBody)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(AppStrings.onboardingGetStarted, action: onContinue)
                    .buttonStyle(AetherPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var model: ScanModel
    let groups: [SidebarGroup]
    @State private var isDropTarget = false

    var body: some View {
        List(selection: Binding(
            get: { model.selectedPath },
            set: { if let p = $0 { model.select(p) } }
        )) {
            ForEach(groups) { group in
                Section(group.title) {
                    ForEach(group.paths, id: \.self) { folderRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive")
                        .font(.system(size: 22, weight: .light))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Aether.accent)
                    Text(AppStrings.appName)
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.33)
                }
                Text(verbatim: "APFS / HFS+")
                    .font(Aether.metadata)
                    .foregroundStyle(Aether.muted)
                if model.isCheckingFolders {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(AppStrings.checkingFolders)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(Aether.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget, perform: model.addDroppedFolders)
        .overlay {
            if model.watchedPaths.isEmpty {
                ContentUnavailableView(AppStrings.noFolders,
                    systemImage: "folder.badge.plus",
                    description: Text(AppStrings.addFolderHelp))
            }
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2, dash: [5]))
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private func folderRow(_ path: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 1) {
                Text((path as NSString).lastPathComponent)
                Text(model.folderSummary(for: path))
                    .font(.system(size: 12))
                    .foregroundStyle(Aether.muted)
                    .lineLimit(1)
            }
        } icon: {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable().frame(width: 16, height: 16)
        }
        .tag(path)
        .contextMenu {
            Button(AppStrings.reveal) {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
            }
            Button(AppStrings.remove, role: .destructive) { model.remove(path: path) }
        }
    }
}

// MARK: - Detail

private struct Detail: View {
    @Bindable var model: ScanModel
    let focus: FocusState<MainFocusRegion?>.Binding

    var body: some View {
        Group {
            switch model.state {
            case .idle:
                ContentUnavailableView(AppStrings.nothingSelected,
                    systemImage: "internaldrive",
                    description: Text(AppStrings.chooseFolder))

            case .failed(let message):
                ContentUnavailableView {
                    Label(AppStrings.cannotScan, systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }

            case .scanning(let progress):
                ScanningView(progress: progress) { model.cancelScan() }

            case .done(let result):
                VStack(spacing: 0) {
                    if !model.toolReady {
                        Text(AppStrings.compressorUnavailable)
                            .font(.system(size: 12)).foregroundStyle(Aether.muted)
                            .padding(8)
                    }
                    if model.showingRecentScan {
                        Text(AppStrings.recentScan)
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ResultView(model: model, result: result, focus: focus)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(AppStrings.settings, systemImage: "slider.horizontal.3") {
                    model.showingSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
                .help(AppStrings.settingsHelp)
            }
            ToolbarItem(placement: .automatic) {
                Button(AppStrings.schedule, systemImage: "calendar.badge.clock") {
                    model.showingInspector.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .help(AppStrings.scheduleHelp)
                .disabled(model.selectedPath == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    Button(AppStrings.stop, systemImage: "stop.fill") { model.cancelScan() }
                } else {
                    Button(AppStrings.rescan, systemImage: "arrow.clockwise") { model.rescan() }
                        .disabled(model.selectedPath == nil)
                }
            }
        }
    }
}

private struct ScanningView: View {
    let progress: ScanProgress
    let onCancel: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            AetherBadge(text: AppStrings.scanProgress)
            ProgressView()
                .controlSize(.large)
            if reduceMotion {
                progressText
            } else {
                progressText.contentTransition(.numericText())
            }
            if let path = progress.currentPath {
                Text(path)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            Button(AppStrings.stop, action: onCancel)
                .buttonStyle(AetherSecondaryButtonStyle())
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: progress.filesSeen)
    }

    private var progressText: some View {
        Text(AppStrings.examined(progress.filesSeen))
            .font(.title3)
            .monospacedDigit()
            .accessibilityLabel(AppStrings.scanProgress)
            .accessibilityValue(AppStrings.examined(progress.filesSeen))
    }
}
