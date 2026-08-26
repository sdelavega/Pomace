import Foundation
import ServiceManagement

/// Registration of the launchd agent that drives scheduled sweeps.
///
/// The agent wakes on a fixed interval and asks the store what is due — it does NOT carry
/// per-directory schedules. The plist lives inside the signed app bundle, so rewriting it to
/// reflect a schedule change would invalidate the code signature. See ADR-0014.
public enum SweepService {

    public static let plistName = "com.sdelavega.Pomace.Sweep.plist"

    /// How often the agent wakes. Each wake is a process spawn, a SQLite read, and an exit
    /// unless something is due — cheap enough to do hourly, frequent enough that a daily
    /// cadence lands near its preferred hour.
    public static let wakeInterval = 3600

    public enum Status: Sendable, Equatable {
        case notRegistered
        case enabled
        case requiresApproval
        case notFound
        case unavailable(String)

        /// Shown verbatim in the UI. The user can disable a login item behind our back, and
        /// pretending otherwise would be a lie about whether their folders are being swept.
        public var explanation: String {
            switch self {
            case .notRegistered: "Scheduled sweeps are off"
            case .enabled: "Scheduled sweeps are on"
            case .requiresApproval:
                "Waiting for your approval in System Settings › General › Login Items"
            case .notFound:
                "Pomace can't register its background helper. Move Pomace to your Applications folder and try again."
            case .unavailable(let reason): reason
            }
        }

        public var isActive: Bool { self == .enabled }
    }

    public static var status: Status {
        let service = SMAppService.agent(plistName: plistName)
        switch service.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .unavailable("Unknown state")
        }
    }

    public struct RegistrationError: Error, CustomStringConvertible {
        public let description: String
    }

    @discardableResult
    public static func register() -> Result<Status, RegistrationError> {
        let service = SMAppService.agent(plistName: plistName)
        do {
            try service.register()
            return .success(status)
        } catch {
            return .failure(RegistrationError(description: (error as NSError).localizedDescription))
        }
    }

    @discardableResult
    public static func unregister() -> Result<Status, RegistrationError> {
        let service = SMAppService.agent(plistName: plistName)
        do {
            try service.unregister()
            return .success(status)
        } catch {
            return .failure(RegistrationError(description: (error as NSError).localizedDescription))
        }
    }

    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
