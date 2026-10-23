import Foundation
import AppKit
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
    private var installationLock: SweepLock?
    private var stagedInstall = false

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

    // Main retains Updates for the GUI process lifetime, including installation handoff.
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

    private func reserveInstallation() -> Bool {
        if installationLock != nil { return true }
        installationLock = SweepLock.acquire(at: lockURL)
        return installationLock != nil
    }

    private func waitForReservation(_ handler: @escaping () -> Void) {
        relaunchTask?.cancel()
        relaunchTask = Task { @MainActor [weak self] in
            while let self, !self.reserveInstallation() {
                do { try await Task.sleep(for: .seconds(self.pollInterval)) }
                catch { return }
            }
            guard self != nil, !Task.isCancelled else { return }
            handler()
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        if reserveInstallation() { return false }
        waitForReservation(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        stagedInstall = true
        return false
    }

    func shouldTerminate(reply: @escaping () -> Void) -> NSApplication.TerminateReply {
        guard stagedInstall else { return .terminateNow }
        if reserveInstallation() { return .terminateNow }
        waitForReservation(reply)
        return .terminateLater
    }
}

@MainActor
final class UpdateTerminationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Main.updates?.shouldTerminate { sender.reply(toApplicationShouldTerminate: true) } ?? .terminateNow
    }
}
