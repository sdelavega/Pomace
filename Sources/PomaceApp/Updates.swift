import Foundation
import Sparkle
import SwiftUI
import PomaceCore

@MainActor
final class Updates: NSObject, ObservableObject, SPUUpdaterDelegate {
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private let lockURL: URL
    private let pollInterval: TimeInterval
    private var relaunchTask: Task<Void, Never>?

    var updater: SPUUpdater { controller.updater }

    init(startingUpdater: Bool, lockURL: URL = SweepLock.defaultURL, pollInterval: TimeInterval = 5) {
        self.lockURL = lockURL
        self.pollInterval = pollInterval
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: self, userDriverDelegate: nil)
        observations = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.objectWillChange.send() }
            }
        ]
        if startingUpdater { controller.startUpdater() }
    }

    deinit { relaunchTask?.cancel() }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        updater.checkForUpdates()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard SweepLock.isHeld(at: lockURL) else { return false }
        relaunchTask?.cancel()
        relaunchTask = Task { @MainActor [lockURL, pollInterval] in
            repeat {
                do { try await Task.sleep(for: .seconds(pollInterval)) }
                catch { return }
            } while SweepLock.isHeld(at: lockURL)
            guard !Task.isCancelled else { return }
            installHandler()
        }
        return true
    }
}
