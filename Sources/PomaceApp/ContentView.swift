import SwiftUI
import AppKit
import PomaceCore

struct ContentView: View {
    @Bindable var model: ScanModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            Detail(model: model)
                .inspector(isPresented: $model.showingInspector) {
                    InspectorView(model: model)
                }
        }
        .navigationTitle("Pomace")
        .confirmationDialog(
            "Decompress \(Fmt.count(model.compressedCount, "file"))?",
            isPresented: $model.confirmingDecompress,
            titleVisibility: .visible
        ) {
            Button("Decompress \(Fmt.count(model.compressedCount, "file"))", role: .destructive) {
                model.confirmDecompress()
            }
            Button("Cancel", role: .cancel) { model.confirmingDecompress = false }
        } message: {
            // Naming the count is the point: afsctool's -d strips the entire resource fork,
            // so this must never be reachable by a single unconsidered click (SAFETY.md §4).
            Text("""
                 This returns those files to their full size on disk. \
                 Their contents are unchanged, and you can compress them again at any time.
                 """)
        }
        .sheet(isPresented: $model.showingSettings) {
            AdvancedSettingsView(model: model)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.showingSettings = false }
                    }
                }
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Bindable var model: ScanModel

    var body: some View {
        List(selection: Binding(
            get: { model.selectedPath },
            set: { if let p = $0 { model.select(p) } }
        )) {
            Section("Folders") {
                ForEach(model.watchedPaths, id: \.self) { path in
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text((path as NSString).lastPathComponent)
                            Text((path as NSString).deletingLastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable().frame(width: 16, height: 16)
                    }
                    .tag(path)
                    .contextMenu {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                        }
                        Button("Remove", role: .destructive) { model.remove(path: path) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.watchedPaths.isEmpty {
                ContentUnavailableView("No Folders",
                    systemImage: "folder.badge.plus",
                    description: Text("Add a folder to see what compression would reclaim."))
            }
        }
    }
}

// MARK: - Detail

private struct Detail: View {
    @Bindable var model: ScanModel

    var body: some View {
        Group {
            switch model.state {
            case .idle:
                ContentUnavailableView("Nothing Selected",
                    systemImage: "internaldrive",
                    description: Text("Choose a folder in the sidebar, or press ⌘O to add one."))

            case .failed(let message):
                ContentUnavailableView {
                    Label("Can't Scan This Folder", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }

            case .scanning(let progress):
                ScanningView(progress: progress) { model.cancelScan() }

            case .done(let result):
                if model.toolReady {
                    ResultView(model: model, result: result)
                } else {
                    InstallToolView(model: model)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Settings", systemImage: "slider.horizontal.3") {
                    model.showingSettings = true
                }
                .help("See what Pomace chose, and why")
            }
            ToolbarItem(placement: .automatic) {
                Button("Schedule", systemImage: "calendar.badge.clock") {
                    model.showingInspector.toggle()
                }
                .help("Schedule and sweep history")
                .disabled(model.selectedPath == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                if model.isScanning {
                    Button("Stop", systemImage: "stop.fill") { model.cancelScan() }
                } else {
                    Button("Rescan", systemImage: "arrow.clockwise") { model.rescan() }
                        .disabled(model.selectedPath == nil)
                }
            }
        }
    }
}

private struct ScanningView: View {
    let progress: ScanProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("\(Fmt.count(progress.filesSeen, "file")) examined")
                .font(.title3)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let path = progress.currentPath {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 420)
            }
            Button("Stop", action: onCancel)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.default, value: progress.filesSeen)
    }
}
