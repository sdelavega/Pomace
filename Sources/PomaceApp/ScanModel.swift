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
    var installation: ToolInstallation?
    var confirmingDecompress = false
    var showingSettings = false
    var showingInspector = false
    var showingOnboarding = false
    var schedule = SweepSchedule()
    var sweepHistory: [Store.SweepRun] = []
    var snapshotHistory: [Store.SnapshotSummary] = []
    var serviceStatus: SweepService.Status = .notRegistered
    var serviceError: String?
    var isSweeping = false

    enum SortOrder: String, CaseIterable, Identifiable {
        case potentialSaving = "Largest first"
        case name = "Name"
        case state = "Compression state"
        var id: String { rawValue }
    }

    private var scanTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private let store: Store?
    let log = MutationLog()

    init() {
        // A broken store must not stop the app from scanning — it only costs us history.
        store = try? Store()
        watchedPaths = (try? store?.watchedDirectories()) .flatMap { $0 } ?? []
        installation = CompressorTool.discover()
        serviceStatus = SweepService.status
        showingOnboarding = !UserDefaults.standard.bool(forKey: "hasSeenOnboarding")
    }

    // MARK: - Scheduling

    /// Turning scheduled sweeps on registers a launchd agent, which appears in the user's
    /// Login Items. The UI reports the real service status rather than assuming success —
    /// the user can disable it behind our back, and claiming their folders are being swept
    /// when they are not would be the worst kind of lie for this app to tell.
    func setScheduledSweepsEnabled(_ enabled: Bool) {
        serviceError = nil
        let result = enabled ? SweepService.register() : SweepService.unregister()
        switch result {
        case .success(let status): serviceStatus = status
        case .failure(let error):
            serviceError = error.description
            serviceStatus = SweepService.status
        }
    }

    func refreshServiceStatus() { serviceStatus = SweepService.status }

    func openLoginItems() { SweepService.openLoginItemsSettings() }

    func loadSchedule(for path: String) {
        let entry = (try? store?.watched())?.flatMap { $0 }?.first { $0.path == path }
        schedule = entry?.schedule ?? SweepSchedule()
        if let m = entry?.mode { mode = m }
        sweepHistory = (try? store?.sweepHistory(path: path)).flatMap { $0 } ?? []
        snapshotHistory = (try? store?.snapshotHistory(path: path)).flatMap { $0 } ?? []
    }

    func saveSchedule() {
        guard let path = selectedPath else { return }
        try? store?.updateSchedule(path: path, schedule: schedule, mode: mode)
        if schedule.enabled, schedule.cadence != .manual, !serviceStatus.isActive {
            setScheduledSweepsEnabled(true)
        }
    }

    var nextSweepDescription: String {
        guard schedule.enabled, schedule.cadence != .manual else { return "No scheduled sweeps" }
        guard serviceStatus.isActive else { return serviceStatus.explanation }
        guard let path = selectedPath,
              let last = (try? store?.lastCompletedSweep(path: path)).flatMap({ $0 }),
              let interval = schedule.cadence.interval else {
            return "Will sweep at the next opportunity"
        }
        let next = last.addingTimeInterval(interval)
        if next <= Date() { return "Due now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Next sweep \(f.localizedString(for: next, relativeTo: Date()))"
    }

    /// Runs a sweep immediately for the selected folder, through the same runner the agent
    /// uses — so "Sweep Now" exercises the scheduled path rather than a parallel one.
    func sweepNow() {
        guard let path = selectedPath, let store, let install = installation else { return }
        isSweeping = true
        Task { [weak self] in
            let runner = SweepRunner(store: store, log: self?.log ?? MutationLog())
            let dir = Store.WatchedDirectory(id: 0, path: path,
                                             schedule: self?.schedule ?? SweepSchedule(),
                                             mode: self?.mode ?? .automatic)
            let report = await runner.sweep(dir, installation: install, lastRun: nil)
            guard let self else { return }
            self.isSweeping = false
            self.loadSchedule(for: path)
            if let deferral = report.deferral {
                self.runState = .refused(deferral.explanation)
            } else if let error = report.error {
                self.runState = .refused(error)
            } else {
                var outcome = CompressionOutcome()
                outcome.filesSucceeded = report.filesCompressed
                outcome.bytesBefore = report.bytesReclaimed
                outcome.duration = report.duration
                self.runState = .finished(outcome)
            }
            self.scan(path)
        }
    }

    // MARK: - Compressor

    var toolReady: Bool { installation?.capabilities.isUsable ?? false }

    var toolSummary: String {
        guard let i = installation else { return "\(CompressorTool.displayName) isn't installed" }
        let v = i.capabilities.version.map { "\(CompressorTool.displayName) \($0)" } ?? CompressorTool.displayName
        return "\(v) — from \(i.source.description)"
    }

    func refreshInstallation() { installation = CompressorTool.discover() }

    func dismissOnboarding() {
        UserDefaults.standard.set(true, forKey: "hasSeenOnboarding")
        showingOnboarding = false
    }

    // MARK: - Compression

    var isRunning: Bool { if case .running = runState { true } else { false } }

    var plan: CompressionPlan {
        CompressionPolicy.plan(
            mode: mode,
            conditions: RuntimeConditions.current(volumePath: selectedPath),
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
                    // Post-run truth: re-scan natively rather than trusting the compressor's
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
            _ = try? store?.addWatchedDirectory(path: path)
            watchedPaths.append(path)
        }
        selectedPath = path
        loadSchedule(for: path)
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
        loadSchedule(for: path)
        scan(path)
    }

    /// Restores the previously selected folder on launch, scanning it so the detail pane is
    /// never left empty next to a highlighted sidebar row.
    func restoreSelection() {
        guard selectedPath == nil, let first = watchedPaths.first else { return }
        selectedPath = first
        loadSchedule(for: first)
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
                    _ = try? self.store?.record(r)
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
