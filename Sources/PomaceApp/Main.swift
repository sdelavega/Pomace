import Foundation
import AppKit
import PomaceCore

/// Entry point. Argument dispatch happens BEFORE any SwiftUI scene is constructed, so a
/// scheduled sweep never briefly flashes a Dock icon or a window.
///
/// This is the same executable the GUI runs (ADR-0006): one code signature means one TCC
/// identity, so the disk access the user grants Pomace is the access the sweep runs under.
@main
enum Main {

    static func main() {
        let args = CommandLine.arguments

        if args.contains("--sweep-all") || args.contains("--sweep-now") {
            runHeadlessSweep(force: args.contains("--sweep-now"))
            exit(0)
        }

        // Service management from the command line. SMAppService validates that the calling
        // process's bundle contains the plist, so this must run from inside Pomace.app —
        // a standalone helper binary cannot register the agent on its behalf.
        if args.contains("--register-sweeps") {
            exit(reportService(SweepService.register()))
        }
        if args.contains("--unregister-sweeps") {
            exit(reportService(SweepService.unregister()))
        }
        if args.contains("--service-status") {
            print("\(SweepService.status): \(SweepService.status.explanation)")
            exit(0)
        }

        PomaceApp.main()
    }

    private static func reportService(
        _ result: Result<SweepService.Status, SweepService.RegistrationError>
    ) -> Int32 {
        switch result {
        case .success(let status):
            print("\(status): \(status.explanation)")
            return status.isActive || status == .notRegistered ? 0 : 1
        case .failure(let error):
            print("failed: \(error.description)")
            return 1
        }
    }

    private static func runHeadlessSweep(force: Bool) {
        // Belt and braces: nothing here should touch AppKit, but if some framework pulls it
        // in, refuse an activation policy that would put us in the Dock.
        NSApplication.shared.setActivationPolicy(.prohibited)

        let log = MutationLog()
        guard let store = try? Store() else {
            log.note("sweep aborted — could not open the store")
            return
        }

        // Task.detached, never Task {} — top-level code runs on the main actor, and a
        // main-actor task plus a blocking wait is the deadlock M1 spent an hour on.
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .background) {
            let runner = SweepRunner(store: store, log: log)
            let reports = await runner.sweepAll(force: force)
            report(reports, log: log)
            done.signal()
        }
        done.wait()
    }

    private static func report(_ reports: [SweepReport], log: MutationLog) {
        guard !reports.isEmpty else { return }
        var failures: [SweepReport] = []
        for r in reports {
            if let d = r.deferral {
                log.note("sweep \(r.path): \(d.rawValue)")
            } else if let e = r.error {
                log.note("sweep \(r.path): FAILED \(e)")
                failures.append(r)
            } else {
                log.note("sweep \(r.path): \(r.filesCompressed) compressed, "
                         + "\(ByteFormat.short(r.bytesReclaimed)) reclaimed"
                         + (r.wasIncremental ? " (incremental)" : " (full pass)"))
                if r.filesFailed > 0 { failures.append(r) }
            }
        }
        // Notify on trouble only. A sweep that worked is not news, and a notification every
        // night is how a background feature gets turned off (PRD §5.3).
        if !failures.isEmpty {
            SweepNotifier.notifyFailures(failures)
        }
    }
}
