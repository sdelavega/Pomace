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
                content.title = AppStrings.sweepFailed(name)
                content.body = r.error?.text ?? AppStrings.notificationSkipped(r.filesFailed)
            } else {
                content.title = AppStrings.foldersFailed(reports.count)
                content.body = AppStrings.notificationHelp
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
