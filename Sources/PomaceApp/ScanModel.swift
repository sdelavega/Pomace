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

    enum RunState {
        case none
        case running(CompressionOperation, CompressionProgress)
        case finished(CompressionOutcome)
        case refused(String)
    }

    var state: State = .idle
    var runState: RunState = .none
    var watchedPaths: [String] = []
    var selectedPath: String?
    var showExcluded = false
    var sortOrder: SortOrder = .potentialSaving
    var mode: CompressionMode = .automatic
    var overrides: CompressionSettings?
    var installation: AfsctoolInstallation?
    var confirmingDecompress = false
    var showingSettings = false

    enum SortOrder: String, CaseIterable, Identifiable {
        case potentialSaving = "Largest first"
        case name = "Name"
        case state = "Compression state"
        var id: String { rawValue }
    }

    private var scanTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private let store: Store?
    private let log = MutationLog()

    init() {
        // A broken store must not stop the app from scanning — it only costs us history.
        store = try? Store()
        watchedPaths = (try? store?.watchedDirectories()) .flatMap { $0 } ?? []
        installation = AfsctoolLocator.discover()
    }

    // MARK: - afsctool

    var afsctoolReady: Bool { installation?.capabilities.isUsable ?? false }

    var afsctoolSummary: String {
        guard let i = installation else { return "afsctool isn't installed" }
        let v = i.capabilities.version.map { "afsctool \($0)" } ?? "afsctool"
        return "\(v) — from \(i.source.description)"
    }

    func refreshInstallation() { installation = AfsctoolLocator.discover() }

    // MARK: - Compression

    var isRunning: Bool { if case .running = runState { true } else { false } }

    var plan: CompressionPlan {
        CompressionPolicy.plan(
            mode: mode,
            conditions: RuntimeConditions.current(volumePath: selectedPath),
            foreground: true,
            overrides: overrides,
            capabilities: installation?.capabilities)
    }

    /// Every path the user's current view would act on. Built from the scan, then
    /// re-evaluated inside the engine at mutation time.
    private func targetPaths(for op: CompressionOperation) -> [String] {
        guard let r = result else { return [] }
        switch op {
        case .compress:   return r.entries.filter { !$0.isExcluded && !$0.isCompressed }.map(\.path)
        case .decompress: return r.entries.filter(\.isCompressed).map(\.path)
        }
    }

    var compressibleCount: Int { result?.progress.eligibleFiles ?? 0 }
    var compressedCount: Int { result?.progress.compressedFiles ?? 0 }

    func startCompress() { start(.compress) }

    func requestDecompress() { confirmingDecompress = true }

    func confirmDecompress() {
        confirmingDecompress = false
        start(.decompress)
    }

    private func start(_ op: CompressionOperation) {
        guard let root = selectedPath, let install = installation else { return }
        let paths = targetPaths(for: op)
        guard !paths.isEmpty else {
            runState = .refused(op == .compress
                ? "Nothing here needs compressing."
                : "Nothing here is compressed.")
            return
        }
        let plan = self.plan
        runState = .running(op, CompressionProgress())
        runTask = Task { [weak self] in
            guard let self else { return }
            for await event in CompressionEngine.run(operation: op, paths: paths, root: root,
                                                     installation: install, plan: plan,
                                                     logger: self.log) {
                if Task.isCancelled { return }
                switch event {
                case .started(let p), .progress(let p):
                    self.runState = .running(op, p)
                case .finished(let outcome):
                    self.runState = .finished(outcome)
                    // Post-run truth: re-scan natively rather than trusting afsctool's
                    // summary, so before and after come from the same code path.
                    self.scan(root)
                case .failed(let message):
                    self.runState = .refused(message)
                }
            }
        }
    }

    func cancelRun() {
        runTask?.cancel()
        runTask = nil
    }

    func dismissRunResult() { runState = .none }

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
