import Foundation

/// How often a watched directory is re-swept.
///
/// Note what this is NOT: a launchd calendar entry. The agent plist lives inside the signed
/// app bundle, so its contents cannot be rewritten when the user changes a schedule without
/// invalidating the code signature. Instead the agent wakes on a fixed cheap interval and
/// each directory's cadence is evaluated here, against the store. See ADR-0014.
public enum SweepCadence: String, Sendable, CaseIterable, Identifiable, Codable {
    case daily, weekly, monthly, manual

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .daily: "Every day"
        case .weekly: "Every week"
        case .monthly: "Every month"
        case .manual: "Only when I ask"
        }
    }

    public var interval: TimeInterval? {
        switch self {
        case .daily: 24 * 3600
        case .weekly: 7 * 24 * 3600
        case .monthly: 30 * 24 * 3600
        case .manual: nil
        }
    }
}

public struct SweepSchedule: Sendable, Equatable, Codable {
    public var cadence: SweepCadence = .weekly
    /// Preferred hour of day, 0–23. Advisory: the agent only wakes hourly, so a sweep runs
    /// at the first wake at or after this hour once the cadence is due.
    public var preferredHour: Int = 3
    public var enabled: Bool = true

    public init(cadence: SweepCadence = .weekly, preferredHour: Int = 3, enabled: Bool = true) {
        self.cadence = cadence
        self.preferredHour = max(0, min(23, preferredHour))
        self.enabled = enabled
    }

    /// Whether a sweep is due, given when one last completed.
    public func isDue(lastRun: Date?, now: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, let interval = cadence.interval else { return false }
        guard let last = lastRun else { return true }        // never swept
        let elapsed = now.timeIntervalSince(last)
        guard elapsed >= interval else { return false }
        // Once due, wait for the preferred hour — unless we are more than a full cadence
        // late, in which case the machine was probably asleep and we should just run.
        if elapsed >= interval * 2 { return true }
        return calendar.component(.hour, from: now) >= preferredHour
    }

    public var summary: String {
        guard enabled else { return "Paused" }
        switch cadence {
        case .manual: return "Only when you ask"
        case .daily, .weekly, .monthly:
            let h = preferredHour
            let suffix = h == 0 ? "midnight" : (h < 12 ? "\(h) AM" : (h == 12 ? "noon" : "\(h - 12) PM"))
            return "\(cadence.label), around \(suffix)"
        }
    }
}

/// Reasons a due sweep was skipped. Recorded rather than silently dropped, so the history
/// can explain a gap instead of just showing one.
public enum SweepDeferral: String, Sendable, Codable {
    case onBattery, lowPowerMode, thermalPressure, timeMachineRunning, volumeUnavailable, alreadyRunning

    public var explanation: String {
        switch self {
        case .onBattery: "Skipped — running on battery"
        case .lowPowerMode: "Skipped — Low Power Mode was on"
        case .thermalPressure: "Skipped — the Mac was running warm"
        case .timeMachineRunning: "Skipped — a Time Machine backup was in progress"
        case .volumeUnavailable: "Skipped — the folder wasn't available"
        case .alreadyRunning: "Skipped — another sweep was already running"
        }
    }
}

public enum SweepPreconditions {

    /// Checked at the moment a sweep would start. A background sweep must never compete with
    /// the user's own work, and must never run the battery down (PRD §5.3).
    public static func check(root: String,
                             conditions: RuntimeConditions = .current(),
                             timeMachineRunning: Bool = isTimeMachineRunning()) -> SweepDeferral? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return .volumeUnavailable
        }
        if conditions.thermalPressure { return .thermalPressure }
        if conditions.lowPowerMode { return .lowPowerMode }
        if conditions.onBattery { return .onBattery }
        if timeMachineRunning { return .timeMachineRunning }
        return nil
    }

    /// `tmutil status` is the documented way to ask. Treated as "not running" if it can't be
    /// determined — deferring forever because a query failed would be worse than sweeping.
    public static func isTimeMachineRunning() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/tmutil") else { return false }
        let out = Subprocess.capture("/usr/bin/tmutil", ["status"])
        return out.combined.contains("Running = 1")
    }
}
