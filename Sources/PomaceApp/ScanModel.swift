import Foundation
import Observation
import UniformTypeIdentifiers
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
    private var schedulesByPath: [String: SweepSchedule] = [:]
    var selectedPath: String?
    var showExcluded = false
    var sortOrder: SortOrder = .potentialSaving
    var mode: CompressionMode = .automatic
    var overrides: CompressionSettings?
    var resolution: CompressorResolution
    var resolveCompressor: @Sendable (String?) -> CompressorResolution = { CompressorTool.resolve(customPath: $0) }
    private let defaults: UserDefaults
    private let sweepLockURL: URL
    var confirmingDecompress = false
    var confirmingAdministrator = false
    var useAdministratorPrivileges = false
    private struct PreparedRun {
        let operation: CompressionOperation
        let root: String
        let installation: ToolInstallation
        let paths: [String]
        let plan: CompressionPlan
        let executor: CompressionExecutor
    }
    private var pendingAdministratorRun: PreparedRun?
    var showingReportProblem = false
    var showingSettings = false
    var showingInspector = false
    var showingOnboarding = false
    var schedule = SweepSchedule()
    var sweepHistory: [Store.SweepRun] = []
    var snapshotHistory: [Store.SnapshotSummary] = []
    var serviceStatus: SweepService.Status = .notRegistered
    var serviceError: String?
    var isSweeping = false

    /// The selected folder's exclusion patterns (see `SafetyRules.userExclusions`).
    var exclusions: [String] = []
    private var exclusionsByPath: [String: [String]] = [:]
    /// Compressors measured as best per folder; Automatic mode uses them.
    private var measuredByPath: [String: String] = [:]

    var estimate: SavingsEstimate?
    var isEstimating = false
    var estimateFailed = false
    private var estimateTask: Task<Void, Never>?
    private var estimateCancellation: CompressionCancellation?

    /// How much compression the selected folder has been losing between scans.
    var expansion = ExpansionReport()

    /// How far each folder has drifted from its last compression, as of its latest scan.
    /// Absent for folders Pomace has never finished compressing.
    private(set) var degradationByPath: [String: Degradation] = [:]
    /// Folders whose next scan should become their compression baseline: the native
    /// re-scan that follows a completed Compress.
    private var pendingBaselines: Set<String> = []
    private(set) var isCheckingFolders = false
    private var checkTask: Task<Void, Never>?

    enum SortOrder: String, CaseIterable, Identifiable {
        case potentialSaving = "Largest first"
        case name = "Name"
        case state = "Compression state"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .potentialSaving: AppStrings.largestFirst
            case .name: AppStrings.name
            case .state: AppStrings.compressionState
            }
        }
    }

    private var scanTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var runCancellation: CompressionCancellation?
    private var scanCache = ScanCache()
    var isStopping = false
    var showingRecentScan = false
    private let store: Store?
    let log: MutationLog

    init(store: Store? = try? Store(),
         resolution: CompressorResolution? = nil,
         defaults: UserDefaults = .standard,
         log: MutationLog = MutationLog(),
         sweepLockURL: URL = SweepLock.defaultURL) {
        // A broken store must not stop the app from scanning — it only costs us history.
        self.store = store
        self.log = log
        self.defaults = defaults
        self.sweepLockURL = sweepLockURL
        let watched = (try? store?.watched()) .flatMap { $0 } ?? []
        watchedPaths = watched.map(\.path)
        schedulesByPath = Dictionary(uniqueKeysWithValues: watched.map { ($0.path, $0.schedule) })
        exclusionsByPath = Dictionary(uniqueKeysWithValues: watched.map { ($0.path, $0.exclusions) })
        measuredByPath = Dictionary(uniqueKeysWithValues: watched.compactMap { dir in
            dir.measuredCompressor.map { (dir.path, $0) }
        })
        self.resolution = resolution ?? CompressorTool.resolve(customPath: defaults.string(forKey: CompressorTool.customPathDefaultsKey))
        serviceStatus = SweepService.status
        showingOnboarding = !defaults.bool(forKey: "hasSeenOnboarding")
        // Last: this calls a method on self, so every stored property must be set first.
        for dir in watched { refreshDegradation(for: dir.path) }
    }

    #if DEBUG
    private var isUITestFixture = false

    func prepareUITestFixture(_ path: String) {
        isUITestFixture = true
        watchedPaths = [path]
        selectedPath = path
        showingOnboarding = false
        showingInspector = true
        showExcluded = true
        scan(path)
    }
    #endif

    func diagnosticsContext() -> (roots: [URL], history: [String]) {
        let runs = (try? store?.sweepHistory(limit: 20)) ?? []
        let paths = Set(watchedPaths + [selectedPath].compactMap { $0 } + runs.map(\.path))
        return (paths.sorted().map { URL(fileURLWithPath: $0) }, runs.map(CoreText.diagnosticsHistory))
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
            serviceError = error.text
            serviceStatus = SweepService.status
        }
    }

    func refreshServiceStatus() { serviceStatus = SweepService.status }

    func openLoginItems() { SweepService.openLoginItemsSettings() }

    func loadSchedule(for path: String) {
        let entry = (try? store?.watched())?.flatMap { $0 }?.first { $0.path == path }
        schedule = entry?.schedule ?? SweepSchedule()
        schedulesByPath[path] = schedule
        if let m = entry?.mode { mode = m }
        exclusions = entry?.exclusions ?? exclusionsByPath[path] ?? []
        exclusionsByPath[path] = exclusions
        if let entry { measuredByPath[path] = entry.measuredCompressor }
        sweepHistory = (try? store?.sweepHistory(path: path)).flatMap { $0 } ?? []
        refreshDrift(for: path)
    }

    /// Reloads the coverage timeline and re-expansion analysis after a scan is saved.
    private func refreshDrift(for path: String) {
        snapshotHistory = (try? store?.snapshotHistory(path: path)).flatMap { $0 } ?? []
        let decompressions = (try? store?.decompressions(path: path)).flatMap { $0 } ?? []
        expansion = ExpansionReport.analyze(snapshotHistory, decompressions: decompressions)
    }

    // MARK: - Degradation

    func degradation(for path: String) -> Degradation? { degradationByPath[path] }

    /// Sidebar subtitle: the schedule, plus how degraded the folder is when that matters.
    func folderSummary(for path: String) -> String {
        guard let degradation = degradationByPath[path], degradation.isSignificant else {
            return scheduleSummary(for: path)
        }
        return [scheduleSummary(for: path), AppStrings.degradedShort(Fmt.percent(degradation.fraction))]
            .joined(separator: " · ")
    }

    private func refreshDegradation(for path: String) {
        let baseline = (try? store?.baseline(path: path)).flatMap { $0 }
        let latest = (try? store?.latestSnapshot(path: path)).flatMap { $0 }
        degradationByPath[path] = Degradation.current(baseline: baseline, latest: latest)
    }

    /// Rescans every watched folder in turn, read-only, so the sidebar shows how far each
    /// has drifted since it was last compressed. The selected folder's view is refreshed
    /// too when nothing else is using it.
    func checkAllFolders() {
        guard !isCheckingFolders, !watchedPaths.isEmpty else { return }
        isCheckingFolders = true
        let jobs = watchedPaths.map { ($0, rules(for: $0)) }
        checkTask = Task { [weak self] in
            for (path, rules) in jobs {
                if Task.isCancelled { break }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue,
                      VolumeContext.probe(path: path).blockingReason == nil else { continue }
                var latest: ScanResult?
                for await event in ScanEngine.scan(root: path, rules: rules) {
                    if case .finished(let result) = event { latest = result }
                }
                guard let self else { return }
                guard let result = latest else { continue }
                self.saveScan(result, path: path)
                if self.selectedPath == path, !self.isScanning, !self.isRunning, !self.isSweeping {
                    self.showingRecentScan = false
                    self.state = .done(result)
                }
            }
            self?.isCheckingFolders = false
            self?.checkTask = nil
        }
    }

    /// Persists a finished scan and refreshes everything derived from saved scans.
    private func saveScan(_ result: ScanResult, path: String) {
        if !isRunning && !isSweeping { scanCache.insert(result) }
        _ = try? store?.record(result)
        if pendingBaselines.remove(path) != nil {
            try? store?.setBaseline(path: path, CompressionBaseline(
                recordedAt: Date(),
                compressedLogicalBytes: result.progress.compressedLogicalBytes,
                eligibleLogicalBytes: result.progress.eligibleLogicalBytes))
        }
        refreshDegradation(for: path)
        if selectedPath == path { refreshDrift(for: path) }
    }

    /// The suggested fix for a folder whose writes keep undoing its compression.
    func switchToManualSchedule() {
        schedule.cadence = .manual
        saveSchedule()
    }

    // MARK: - Exclusions

    /// Rules for scanning, compressing or estimating a folder: the built-in safety rules
    /// plus that folder's own exclusions.
    func rules(for path: String) -> SafetyRules {
        SafetyRules(userExclusions: exclusionsByPath[path] ?? [], root: path)
    }

    /// Returns false when the text cannot be used as a name pattern.
    @discardableResult
    func addExclusion(_ raw: String) -> Bool {
        guard let path = selectedPath, let pattern = SafetyRules.normalizedExclusion(raw) else { return false }
        guard !exclusions.contains(where: { $0.caseInsensitiveCompare(pattern) == .orderedSame }) else { return true }
        setExclusions(exclusions + [pattern], for: path)
        return true
    }

    func removeExclusion(_ pattern: String) {
        guard let path = selectedPath else { return }
        setExclusions(exclusions.filter { $0 != pattern }, for: path)
    }

    private func setExclusions(_ list: [String], for path: String) {
        exclusions = list
        exclusionsByPath[path] = list
        try? store?.updateExclusions(path: path, exclusions: list)
        resetEstimate()
        // What counts as eligible just changed, so the current scan is out of date.
        scanCache.invalidate(path)
        if !isRunning && !isSweeping { scan(path) }
    }

    // MARK: - Savings estimate

    var canEstimate: Bool {
        toolReady && !isEstimating && !isRunning && (result?.progress.eligiblePhysicalBytes ?? 0) > 0
    }

    /// Measures this folder on temporary copies of a sample of its eligible files, and
    /// remembers the best compressor for Automatic mode. The user's files are not touched.
    func estimateSavings() {
        guard canEstimate, let root = selectedPath, let current = result, current.root == root,
              let install = resolution.installation else { return }
        let candidates = current.entries.filter(\.isSampleCandidate)
            .map { SampleCandidate(path: $0.path, size: $0.physicalSize) }
        let eligibleBytes = current.progress.eligiblePhysicalBytes
        let log = self.log
        let cancellation = CompressionCancellation()
        resetEstimate()
        estimateCancellation = cancellation
        isEstimating = true
        estimateTask = Task { [weak self] in
            let value = await Task.detached(priority: .userInitiated) {
                SavingsEstimator.estimate(candidates: candidates, eligibleBytes: eligibleBytes, root: root,
                                          installation: install, cancellation: cancellation, logger: log)
            }.value
            guard let self, self.estimateCancellation === cancellation else { return }
            self.isEstimating = false
            self.estimateCancellation = nil
            self.estimate = value
            self.estimateFailed = value == nil
            if let value {
                self.measuredByPath[root] = value.recommendedCompressor
                try? self.store?.updateMeasuredCompressor(path: root, compressor: value.recommendedCompressor)
            }
        }
    }

    private func resetEstimate() {
        estimateCancellation?.request()
        estimateCancellation = nil
        estimateTask = nil
        isEstimating = false
        estimateFailed = false
        estimate = nil
    }

    func saveSchedule() {
        guard let path = selectedPath else { return }
        try? store?.updateSchedule(path: path, schedule: schedule, mode: mode)
        schedulesByPath[path] = schedule
        if schedule.enabled, schedule.cadence != .manual, !serviceStatus.isActive {
            setScheduledSweepsEnabled(true)
        }
    }

    /// The mode picker lives outside the schedule editor, so a mode change has to be saved
    /// on its own. Otherwise scheduled sweeps kept using the previously saved mode, and the
    /// picker silently reverted the next time the folder was selected.
    func persistMode() {
        guard let path = selectedPath, watchedPaths.contains(path) else { return }
        try? store?.updateSchedule(path: path, schedule: schedule, mode: mode)
    }

    var nextSweepDescription: String {
        guard schedule.enabled, schedule.cadence != .manual else { return AppStrings.noScheduledSweeps }
        guard serviceStatus.isActive else { return serviceStatus.text }
        guard let path = selectedPath,
              let last = (try? store?.lastCompletedSweep(path: path)).flatMap({ $0 }),
              let interval = schedule.cadence.interval else {
            return AppStrings.nextOpportunity
        }
        let next = last.addingTimeInterval(interval)
        if next <= Date() { return AppStrings.dueNow }
        return AppStrings.nextSweep(next.formatted(.relative(presentation: .numeric, unitsStyle: .wide)))
    }

    /// Runs a sweep immediately for the selected folder, through the same runner the agent
    /// uses — so "Sweep Now" exercises the scheduled path rather than a parallel one.
    func sweepNow() {
        #if DEBUG
        guard !isUITestFixture else { return }
        #endif
        guard !isRunning, !isSweeping,
              let path = selectedPath, let store, let install = resolution.installation else { return }
        scanCache.invalidate(path)
        isSweeping = true
        Task { [weak self] in
            let runner = SweepRunner(store: store, log: self?.log ?? MutationLog())
            let dir = Store.WatchedDirectory(id: 0, path: path,
                                             schedule: self?.schedule ?? SweepSchedule(),
                                             mode: self?.mode ?? .automatic,
                                             exclusions: self?.exclusionsByPath[path] ?? [],
                                             measuredCompressor: self?.measuredByPath[path])
            let report = await runner.sweep(dir, installation: install, lastRun: nil)
            guard let self else { return }
            self.isSweeping = false
            self.loadSchedule(for: path)
            if let deferral = report.deferral {
                self.runState = .refused(deferral.text)
            } else if let error = report.error {
                self.runState = .refused(error.text)
            } else {
                var outcome = CompressionOutcome()
                outcome.filesSucceeded = report.filesCompressed
                outcome.bytesBefore = report.bytesReclaimed
                outcome.duration = report.duration
                self.runState = .finished(outcome)
            }
            self.refreshAfterMutation(path)
        }
    }

    // MARK: - Compressor

    var toolReady: Bool { resolution.installation?.capabilities.isUsable ?? false }

    var toolSummary: String {
        guard let i = resolution.installation else { return AppStrings.scanningOnly }
        let v = i.capabilities.version.map { "\(CompressorTool.displayName) \($0)" } ?? CompressorTool.displayName
        let source: String
        switch i.source {
        case .bundled: source = AppStrings.bundled
        case .custom: source = AppStrings.custom
        }
        return AppStrings.toolSummary(v, source)
    }

    func refreshCompressor() {
        resolution = CompressorTool.resolve(customPath: defaults.string(forKey: CompressorTool.customPathDefaultsKey))
    }

    func setCustomCompressor(_ path: String?) {
        if let path {
            defaults.set(path, forKey: CompressorTool.customPathDefaultsKey)
        } else {
            defaults.removeObject(forKey: CompressorTool.customPathDefaultsKey)
        }
        refreshCompressor()
    }

    var customCompressorRejectionText: String? {
        resolution.rejectionText
    }

    func dismissOnboarding() {
        defaults.set(true, forKey: "hasSeenOnboarding")
        showingOnboarding = false
    }

    // MARK: - Compression

    var isRunning: Bool { if case .running = runState { true } else { false } }

    var plan: CompressionPlan {
        CompressionPolicy.plan(
            mode: mode,
            conditions: RuntimeConditions.current(volumePath: selectedPath),
            measuredCompressor: selectedPath.flatMap { measuredByPath[$0] },
            overrides: overrides,
            capabilities: resolution.installation?.capabilities)
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

    var administratorAvailable: Bool {
        selectedPath.map { AdministratorAccess.supports(root: $0) } ?? false
    }

    var administratorConfirmationText: String {
        guard let run = pendingAdministratorRun else { return "" }
        let customWarning: String
        switch run.installation.source {
        case .bundled: customWarning = ""
        case .custom: customWarning = AppStrings.customAdministratorWarning
        }
        return AppStrings.administratorConfirmation(
            run.operation == .compress ? AppStrings.compress : AppStrings.decompress,
            run.paths.count, run.root, run.installation.path, customWarning)
    }

    func confirmAdministrator() {
        confirmingAdministrator = false
        guard let run = pendingAdministratorRun else { return }
        pendingAdministratorRun = nil
        guard run.root == selectedPath else {
            runState = .refused(AppStrings.folderChanged)
            return
        }
        launch(run)
    }

    func cancelAdministrator() {
        confirmingAdministrator = false
        pendingAdministratorRun = nil
    }

    /// True while the full target list of a truncated scan is being gathered.
    private(set) var isPreparingRun = false

    private func start(_ op: CompressionOperation) {
        #if DEBUG
        guard !isUITestFixture else { return }
        #endif
        guard !isRunning, !isSweeping, !isPreparingRun,
              let root = selectedPath, let install = resolution.installation else { return }
        guard result?.entriesTruncated == true else {
            prepare(op, root: root, installation: install, paths: targetPaths(for: op))
            return
        }
        // The scan retains at most `maxRetainedEntries` rows, but the button promises every
        // eligible file. Acting on the retained rows alone silently left the rest of a large
        // folder untouched, so walk the tree again off the main actor.
        isPreparingRun = true
        let rules = self.rules(for: root)
        Task { [weak self] in
            let paths = await Task.detached(priority: .userInitiated) {
                ScanEngine.targetPaths(root: root, operation: op, rules: rules)
            }.value
            guard let self else { return }
            self.isPreparingRun = false
            // Dropping the run silently here read as "the Compress button does nothing"
            // (issue 2): the walk finishes long after the press, so refuse visibly instead.
            guard self.selectedPath == root else {
                self.runState = .refused(AppStrings.folderChanged)
                return
            }
            self.prepare(op, root: root, installation: install, paths: paths)
        }
    }

    private func prepare(_ op: CompressionOperation, root: String,
                         installation install: ToolInstallation, paths: [String]) {
        guard !paths.isEmpty else {
            runState = .refused(op == .compress
                ? CompressionEngineError.nothingToDo.text
                : AppStrings.nothingCompressed)
            return
        }
        let run = PreparedRun(operation: op, root: root, installation: install,
                              paths: paths, plan: self.plan,
                              executor: useAdministratorPrivileges ? .administrator(prompt: CoreText.administratorPrompt, fileChangedMessage: CoreText.fileChangedMessage) : .standard)
        if useAdministratorPrivileges {
            guard administratorAvailable else {
                runState = .refused(CompressionEngineError.administratorUnsupported.text)
                return
            }
            pendingAdministratorRun = run
            confirmingAdministrator = true
            return
        }
        launch(run)
    }

    private func launch(_ run: PreparedRun) {
        guard !isRunning, !isSweeping else { return }
        guard let lock = SweepLock.acquire(at: sweepLockURL) else {
            runState = .refused(CompressionEngineError.alreadyRunning.text)
            return
        }
        let op = run.operation, root = run.root
        let install = run.installation, paths = run.paths, plan = run.plan
        let rules = self.rules(for: root)
        let started = Date()
        let cancellation = CompressionCancellation()
        runCancellation = cancellation
        isStopping = false
        scanCache.invalidate(root)
        runState = .running(op, CompressionProgress())
        runTask = Task { [weak self] in
            defer { lock.release() }
            guard let self else { return }
            for await event in CompressionEngine.run(operation: op, paths: paths, root: root,
                                                     installation: install, plan: plan, rules: rules,
                                                     logger: self.log, cancellation: cancellation,
                                                     executor: run.executor, resolveCompressor: self.resolveCompressor) {
                switch event {
                case .resolved(let resolution): self.resolution = resolution
                case .started(let p), .progress(let p):
                    self.runState = .running(op, p)
                case .finished(let outcome):
                    // A terminal state must mean Sparkle and another run can acquire the lock.
                    lock.release()
                    self.runState = .finished(outcome)
                    // Lets drift analysis tell a Decompress apart from re-expansion.
                    try? self.store?.recordManualRun(path: root, startedAt: started, operation: op)
                    switch op {
                    case .compress where !outcome.wasCancelled:
                        // The re-scan below becomes the folder's new "last compression".
                        self.pendingBaselines.insert(root)
                    case .decompress:
                        // Deliberately uncompressed data is not degradation.
                        try? self.store?.clearBaseline(path: root)
                        self.degradationByPath[root] = nil
                    default: break
                    }
                    // Post-run truth: re-scan natively rather than trusting the compressor's
                    // summary, so before and after come from the same code path.
                    self.refreshAfterMutation(root)
                case .failed(let message):
                    lock.release()
                    self.runState = .refused(message.text)
                }
            }
            if self.runCancellation === cancellation {
                self.runCancellation = nil
                self.isStopping = false
                self.runTask = nil
            }
        }
    }

    func cancelRun() {
        guard isRunning, !isStopping else { return }
        isStopping = true
        log.note("stop requested — waiting for the active batch to finish safely")
        runCancellation?.request()
    }

    private func refreshAfterMutation(_ root: String) {
        scanCache.invalidate(root)
        if let path = selectedPath, ScanCache.overlaps(path, root) { scan(path) }
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
            schedulesByPath[path] = SweepSchedule(cadence: .manual)
            exclusionsByPath[path] = []
        }
        selectedPath = path
        useAdministratorPrivileges = false
        cancelAdministrator()
        loadSchedule(for: path)
        scan(path)
    }

    func remove(path: String) {
        try? store?.removeWatchedDirectory(path: path)
        watchedPaths.removeAll { $0 == path }
        schedulesByPath[path] = nil
        exclusionsByPath[path] = nil
        measuredByPath[path] = nil
        degradationByPath[path] = nil
        pendingBaselines.remove(path)
        scanCache.invalidate(path)
        guard selectedPath == path else { return }
        // Selecting the next folder without loading it left its sidebar row highlighted
        // beside an idle detail pane and the removed folder's schedule and history.
        cancelScan()
        selectedPath = nil
        state = .idle
        useAdministratorPrivileges = false
        cancelAdministrator()
        if let next = watchedPaths.first {
            select(next)
        } else {
            schedule = SweepSchedule()
            sweepHistory = []
            snapshotHistory = []
            exclusions = []
            expansion = ExpansionReport()
            resetEstimate()
        }
    }

    func select(_ path: String) {
        guard selectedPath != path else { return }
        selectedPath = path
        useAdministratorPrivileges = false
        cancelAdministrator()
        cancelScan()
        resetEstimate()
        state = .idle
        loadSchedule(for: path)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
           isDirectory.boolValue, let cached = scanCache.result(for: path) {
            showingRecentScan = true
            state = .done(cached)
        } else {
            scan(path)
        }
    }

    func schedule(for path: String) -> SweepSchedule {
        schedulesByPath[path] ?? SweepSchedule(cadence: .manual)
    }

    func isScheduled(_ path: String) -> Bool {
        let schedule = schedule(for: path)
        return schedule.enabled && schedule.cadence != .manual
    }

    func scheduleSummary(for path: String) -> String {
        schedule(for: path).text
    }

    @discardableResult
    func addDroppedFolders(_ providers: [NSItemProvider]) -> Bool {
        let usable = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        for provider in usable {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url, url.isFileURL else { return }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return }
                Task { @MainActor [weak self] in self?.add(path: url.path) }
            }
        }
        return !usable.isEmpty
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
        showingRecentScan = false
        scanCache.invalidate(path)
        // Fail fast and legibly rather than showing an empty tree the user can't explain.
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            state = .failed(AppStrings.folderUnavailable)
            return
        }
        let volume = VolumeContext.probe(path: path)
        if let blocked = volume.blockingReason {
            state = .failed(blocked.text)
            return
        }

        state = .scanning(ScanProgress())
        let rules = self.rules(for: path)
        scanTask = Task { [weak self] in
            for await event in ScanEngine.scan(root: path, rules: rules) {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .progress(let p):
                    self.state = .scanning(p)
                case .finished(let r):
                    self.state = .done(r)
                    self.saveScan(r, path: path)
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
