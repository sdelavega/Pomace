import Foundation
@preconcurrency import UserNotifications
import PomaceCore

/// Notifications for sweeps that went wrong. Never for ones that went right.
enum SweepNotifier {

    static func notifyFailures(_ reports: [SweepReport]) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            let content = UNMutableNotificationContent()
            if reports.count == 1, let r = reports.first {
                let name = (r.path as NSString).lastPathComponent
                content.title = "Pomace couldn't finish sweeping \(name)"
                content.body = r.error ?? "\(r.filesFailed) file\(r.filesFailed == 1 ? "" : "s") were skipped."
            } else {
                content.title = "Pomace had trouble with \(reports.count) folders"
                content.body = "Open Pomace to see which files were skipped and why."
            }
            content.sound = nil
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            center.add(request)
        }
        // The notification is delivered asynchronously; give it a moment before the
        // short-lived sweep process exits out from under it.
        Thread.sleep(forTimeInterval: 0.5)
    }

    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert]) { _, _ in }
        }
    }
}
