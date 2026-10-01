import Foundation

/// Short-lived display snapshots. Mutation still rechecks every file's safety.
public struct ScanCache {
    private struct Snapshot {
        let result: ScanResult
        let date: Date
    }
    private var snapshots: [String: Snapshot] = [:]
    private let lifetime: TimeInterval
    private let capacity: Int

    public init(lifetime: TimeInterval = 60, capacity: Int = 3) {
        self.lifetime = lifetime
        self.capacity = max(1, capacity)
    }

    public mutating func result(for path: String, now: Date = Date()) -> ScanResult? {
        guard let snapshot = snapshots[path] else { return nil }
        let age = now.timeIntervalSince(snapshot.date)
        guard age >= 0, age < lifetime else {
            snapshots[path] = nil
            return nil
        }
        return snapshot.result
    }

    public mutating func insert(_ result: ScanResult, now: Date = Date()) {
        snapshots[result.root] = Snapshot(result: result, date: now)
        while snapshots.count > capacity,
              let oldest = snapshots.min(by: { $0.value.date < $1.value.date })?.key {
            snapshots[oldest] = nil
        }
    }

    public static func overlaps(_ first: String, _ second: String) -> Bool {
        let a = URL(fileURLWithPath: first).resolvingSymlinksInPath().standardized.pathComponents
        let b = URL(fileURLWithPath: second).resolvingSymlinksInPath().standardized.pathComponents
        return a.starts(with: b) || b.starts(with: a)
    }

    public mutating func invalidate(_ path: String) {
        for key in Array(snapshots.keys) where Self.overlaps(key, path) {
            snapshots[key] = nil
        }
    }
}
