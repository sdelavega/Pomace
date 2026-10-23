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
            Sidebar(model: model)
                .focused($focusedRegion, equals: .sidebar)
                .focusSection()
                .accessibilityLabel(AppStrings.folders)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Detail(model: model, focus: $focusedRegion)
                .inspector(isPresented: $model.showingInspector) {
                    InspectorView(model: model)
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
                .keyboardShortcut(.cancelAction)
                .keyboardShortcut(.defaultAction)
        } message: {
            // Returning files to their full on-disk size must never be a one-click surprise.
            Text(AppStrings.decompressExplanation)
        }
        .modifier(AdministratorConfirmation(model: model))
        .sheet(isPresented: $model.showingSettings) {
            AdvancedSettingsView(model: model)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(AppStrings.done) { model.showingSettings = false }
                    }
                }
        }
        .sheet(isPresented: $model.showingOnboarding) {
            OnboardingView(onContinue: model.dismissOnboarding)
        }
    }

    private var sidebarAccessibilityLabels: [String] {
        let scheduled = model.watchedPaths.filter(model.isScheduled)
        let unscheduled = model.watchedPaths.filter { !model.isScheduled($0) }
        func names(_ paths: [String]) -> [String] {
            paths.map { AppStrings.accessibilityDetail(($0 as NSString).lastPathComponent,
                                                       model.scheduleSummary(for: $0)) }
        }
        return (scheduled.isEmpty ? [] : [AppStrings.scheduled] + names(scheduled))
            + (unscheduled.isEmpty ? [] : [AppStrings.notScheduled] + names(unscheduled))
    }
}

private struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "internaldrive")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(AppStrings.onboardingTitle).font(.system(.title, weight: .semibold))
            Text(AppStrings.onboardingBody)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(AppStrings.onboardingGetStarted, action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 420, idealWidth: 460, maxWidth: 520)
    }
}

// SwiftUI does not pass cell text through to native row labels. Supply those labels and
// the system's localized subrole names for otherwise unnamed standard window/scroller buttons.
private struct NativeAccessibilityLabels: NSViewRepresentable {
    let sidebarLabels: [String]
    let fileEntries: [ScanEntry]

    func makeNSView(context: Context) -> LabelingView { LabelingView() }

    func updateNSView(_ view: LabelingView, context: Context) {
        view.sidebarLabels = sidebarLabels
        view.fileEntries = fileEntries
        DispatchQueue.main.async { view.applyLabels() }
    }

    final class LabelingView: NSView {
        var sidebarLabels: [String] = []
        var fileEntries: [ScanEntry] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setAccessibilityElement(false)
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(applyLabels),
                                                       name: NSWindow.didUpdateNotification, object: window)
            }
        }

        @objc func applyLabels() {
            guard let window else { return }
            var visited: Set<ObjectIdentifier> = []
            func labelButtons(_ element: any NSAccessibilityProtocol, depth: Int) {
                guard depth < 24, visited.count < 20_000,
                      visited.insert(ObjectIdentifier(element)).inserted else { return }
                if element.accessibilityRole() == .button,
                   (element.accessibilityLabel() ?? "").isEmpty,
                   (element.accessibilityTitle() ?? "").isEmpty,
                   let subrole = element.accessibilitySubrole(),
                   let name = NSAccessibility.Role.button.description(with: subrole) {
                    element.setAccessibilityLabel(name)
                }
                for child in element.accessibilityChildren() ?? [] {
                    if let child = child as? any NSAccessibilityProtocol { labelButtons(child, depth: depth + 1) }
                }
            }
            labelButtons(window, depth: 0)
            func labelTables(_ view: NSView) {
                if let table = view as? NSTableView {
                    // Virtual outline rows do not adopt the modern protocol. The public
                    // legacy override API supplies their descriptions without replacing them.
                    let rows = table.accessibilityAttributeValue(.visibleRows) as? [NSObject] ?? []
                    let visibleRange = table.rows(in: table.visibleRect)
                    for (offset, row) in rows.enumerated() {
                        let index = (row.accessibilityAttributeValue(.index) as? NSNumber)?.intValue
                            ?? visibleRange.location + offset
                        let name: String
                        if table.numberOfColumns == 4, fileEntries.indices.contains(index) {
                            let entry = fileEntries[index]
                            name = AppStrings.accessibilityDetail(entry.name, ListFormatter.localizedString(byJoining: [
                                AppStrings.accessibilityDetail(AppStrings.size, Fmt.bytes(entry.logicalSize)),
                                AppStrings.accessibilityDetail(AppStrings.onDisk, Fmt.bytes(entry.physicalSize)),
                                FileRowState(entry: entry).accessibilityLabelText,
                            ]))
                        } else if table.numberOfColumns == 1, sidebarLabels.indices.contains(index) {
                            name = sidebarLabels[index]
                        } else { continue }
                        row.accessibilitySetOverrideValue(name, forAttribute: .description)
                    }
                }
                view.subviews.forEach(labelTables)
            }
            if let content = window.contentView { labelTables(content) }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var model: ScanModel
    @State private var isDropTarget = false

    var body: some View {
        List(selection: Binding(
            get: { model.selectedPath },
            set: { if let p = $0 { model.select(p) } }
        )) {
            let scheduled = model.watchedPaths.filter(model.isScheduled)
            let unscheduled = model.watchedPaths.filter { !model.isScheduled($0) }

            if !scheduled.isEmpty {
                Section(AppStrings.scheduled) {
                    ForEach(scheduled, id: \.self) { folderRow($0) }
                }
            }
            if !unscheduled.isEmpty {
                Section(AppStrings.notScheduled) {
                    ForEach(unscheduled, id: \.self) { folderRow($0) }
                }
            }
        }
        .listStyle(.sidebar)
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
                Text(model.scheduleSummary(for: path))
                    .font(.caption)
                    .foregroundStyle(model.isScheduled(path) ? .secondary : .tertiary)
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
                            .font(.caption).foregroundStyle(.secondary)
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
            ProgressView()
                .controlSize(.large)
            if reduceMotion {
                progressText
            } else {
                progressText.contentTransition(.numericText())
            }
            if let path = progress.currentPath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            Button(AppStrings.stop, action: onCancel)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .default, value: progress.filesSeen)
    }

    private var progressText: some View {
        Text(AppStrings.examined(progress.filesSeen))
            .font(.title3)
            .monospacedDigit()
            .accessibilityLabel(AppStrings.scanProgress)
            .accessibilityValue(AppStrings.examined(progress.filesSeen))
    }
}
