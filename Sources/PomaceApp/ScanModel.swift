import Foundation
import Observation
import PomaceCore

@MainActor
@Observable
final class ScanModel {

    enum State {
        case idle
        case scanning(ScanProgress)
        case done(ScanResult)
        case failed(String)
    }

    var state: State = .idle
    var watchedPaths: [String] = []
    var selectedPath: String?
    var showExcluded = false
    var sortOrder: SortOrder = .potentialSaving

    enum SortOrder: String, CaseIterable, Identifiable {
        case potentialSaving = "Largest first"
        case name = "Name"
        case state = "Compression state"
        var id: String { rawValue }
    }

    private var scanTask: Task<Void, Never>?
    private let store: Store?

    init() {
        // A broken store must not stop the app from scanning — it only costs us history.
        store = try? Store()
        watchedPaths = (try? store?.watchedDirectories()) .flatMap { $0 } ?? []
    }

    var isScanning: Bool { if case .scanning = state { true } else { false } }

    var result: ScanResult? { if case .done(let r) = state { r } else { nil } }

    var progress: ScanProgress? {
        switch state {
        case .scanning(let p): p
        case .done(let r): r.progress
        default: nil
        }
    }

    // MARK: - Directories

    func add(path: String) {
        // Adding a folder already in the list must still select AND scan it. An earlier
        // version returned early here, so relaunching onto a remembered folder left the
        // sidebar row selected while the detail pane said "Nothing Selected".
        if !watchedPaths.contains(path) {
            try? store?.addWatchedDirectory(path: path)
            watchedPaths.append(path)
        }
        selectedPath = path
        scan(path)
    }

    func remove(path: String) {
        try? store?.removeWatchedDirectory(path: path)
        watchedPaths.removeAll { $0 == path }
        if selectedPath == path { selectedPath = watchedPaths.first; state = .idle }
    }

    func select(_ path: String) {
        guard selectedPath != path else { return }
        selectedPath = path
        state = .idle
        scan(path)
    }

    /// Restores the previously selected folder on launch, scanning it so the detail pane is
    /// never left empty next to a highlighted sidebar row.
    func restoreSelection() {
        guard selectedPath == nil, let first = watchedPaths.first else { return }
        selectedPath = first
        scan(first)
    }

    // MARK: - Scanning

    func scan(_ path: String) {
        cancelScan()
        // Fail fast and legibly rather than showing an empty tree the user can't explain.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            state = .failed("That folder is no longer available. It may have been moved, renamed, or its disk ejected.")
            return
        }
        let volume = VolumeContext.probe(path: path)
        if let blocked = volume.blockingReason {
            state = .failed(blocked.explanation)
            return
        }

        state = .scanning(ScanProgress())
        scanTask = Task { [weak self] in
            for await event in ScanEngine.scan(root: path) {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .progress(let p):
                    self.state = .scanning(p)
                case .finished(let r):
                    self.state = .done(r)
                    try? self.store?.record(r)
                }
            }
        }
    }

    func rescan() { if let p = selectedPath { scan(p) } }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        if isScanning { state = .idle }
    }

    // MARK: - Presentation

    var visibleEntries: [ScanEntry] {
        guard let r = result else { return [] }
        let base = showExcluded ? r.entries : r.entries.filter { !$0.isExcluded }
        switch sortOrder {
        case .potentialSaving: return base.sorted { $0.logicalSize > $1.logicalSize }
        case .name:            return base.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .state:           return base.sorted { ($0.isCompressed ? 1 : 0) < ($1.isCompressed ? 1 : 0) }
        }
    }
}
