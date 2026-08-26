import Foundation
import SQLite3

/// SQLite persistence in WAL mode.
///
/// Not SwiftData or Core Data: the GUI and the headless sweep are separate concurrent
/// processes against one file, which needs WAL and explicit transaction discipline.
/// See ADR-0007.
///
/// M1 stores watched directories and per-scan *aggregates*. Per-file rows are deferred to
/// M2 — a single scan can produce hundreds of thousands of them and the schema for pruning
/// them should be designed alongside the code that reads them back.
public final class Store: @unchecked Sendable {

    public enum StoreError: Error, CustomStringConvertible {
        case open(String), sql(String)
        public var description: String {
            switch self {
            case .open(let m): "could not open store: \(m)"
            case .sql(let m): "sql error: \(m)"
            }
        }
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.sdelavega.Pomace.Store")

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pomace", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("pomace.sqlite")
    }

    public init(url: URL? = nil) throws {
        let path = (url ?? Self.defaultURL).path
        guard sqlite3_open_v2(path, &db,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            throw StoreError.open(String(cString: sqlite3_errmsg(db)))
        }
        try exec("PRAGMA journal_mode=WAL;")      // required for cross-process access
        try exec("PRAGMA foreign_keys=ON;")
        try exec("PRAGMA busy_timeout=5000;")     // the sweep may hold a write lock
        try migrate()
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    // MARK: - Schema

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS watched_directory (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            path         TEXT NOT NULL UNIQUE,
            added_at     REAL NOT NULL,
            compressor   TEXT,
            enabled      INTEGER NOT NULL DEFAULT 1
        );
        CREATE TABLE IF NOT EXISTS scan_snapshot (
            id                    INTEGER PRIMARY KEY AUTOINCREMENT,
            directory_id          INTEGER REFERENCES watched_directory(id) ON DELETE CASCADE,
            path                  TEXT NOT NULL,
            scanned_at            REAL NOT NULL,
            duration              REAL NOT NULL,
            files                 INTEGER NOT NULL,
            directories           INTEGER NOT NULL,
            logical_bytes         INTEGER NOT NULL,
            physical_bytes        INTEGER NOT NULL,
            compressed_files      INTEGER NOT NULL,
            compressed_logical    INTEGER NOT NULL,
            compressed_physical   INTEGER NOT NULL,
            excluded_files        INTEGER NOT NULL,
            eligible_files        INTEGER NOT NULL,
            eligible_logical      INTEGER NOT NULL,
            hard_link_duplicates  INTEGER NOT NULL,
            unreadable_entries    INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_snapshot_path_time
            ON scan_snapshot(path, scanned_at DESC);
        """)
        if try scalarLocked("SELECT COUNT(*) FROM schema_version") == 0 {
            try exec("INSERT INTO schema_version (version) VALUES (1);")
        }
        try migrateToV2()
    }

    /// M3 adds schedules and sweep history. Columns are added rather than the table
    /// recreated, so an existing store keeps its scan history.
    private func migrateToV2() throws {
        guard try scalarLocked("SELECT COALESCE(MAX(version), 0) FROM schema_version") < 2 else { return }
        for column in [
            "cadence TEXT NOT NULL DEFAULT 'weekly'",
            "preferred_hour INTEGER NOT NULL DEFAULT 3",
            "schedule_enabled INTEGER NOT NULL DEFAULT 1",
            "mode TEXT NOT NULL DEFAULT 'Automatic'",
        ] {
            // ALTER TABLE ADD COLUMN throws if the column already exists; that is fine.
            try? exec("ALTER TABLE watched_directory ADD COLUMN \(column);")
        }
        try exec("""
        CREATE TABLE IF NOT EXISTS sweep_run (
            id                INTEGER PRIMARY KEY AUTOINCREMENT,
            path              TEXT NOT NULL,
            started_at        REAL NOT NULL,
            duration          REAL NOT NULL,
            files_compressed  INTEGER NOT NULL DEFAULT 0,
            files_failed      INTEGER NOT NULL DEFAULT 0,
            bytes_reclaimed   INTEGER NOT NULL DEFAULT 0,
            deferral          TEXT,
            error             TEXT,
            cancelled         INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_sweep_path_time ON sweep_run(path, started_at DESC);
        """)
        try exec("UPDATE schema_version SET version = 2;")
    }

    // MARK: - Watched directories

    @discardableResult
    public func addWatchedDirectory(path: String) throws -> Int64 {
        try queue.sync {
            try run("INSERT OR IGNORE INTO watched_directory (path, added_at) VALUES (?, ?);",
                    [.text(path), .real(Date().timeIntervalSince1970)])
            return try scalarLocked("SELECT id FROM watched_directory WHERE path = ?;", [.text(path)])
        }
    }

    public func removeWatchedDirectory(path: String) throws {
        try queue.sync { try run("DELETE FROM watched_directory WHERE path = ?;", [.text(path)]) }
    }

    public struct WatchedDirectory: Sendable, Identifiable {
        public let id: Int64
        public let path: String
        public var schedule: SweepSchedule
        public var mode: CompressionMode

        public init(id: Int64, path: String, schedule: SweepSchedule, mode: CompressionMode) {
            self.id = id; self.path = path; self.schedule = schedule; self.mode = mode
        }
    }

    public func watched() throws -> [WatchedDirectory] {
        try queue.sync {
            var out: [WatchedDirectory] = []
            try query("""
                SELECT id, path, cadence, preferred_hour, schedule_enabled, mode
                FROM watched_directory ORDER BY added_at;
                """) { stmt in
                let cadence = SweepCadence(rawValue: String(cString: sqlite3_column_text(stmt, 2))) ?? .weekly
                let mode = CompressionMode(rawValue: String(cString: sqlite3_column_text(stmt, 5))) ?? .automatic
                out.append(WatchedDirectory(
                    id: sqlite3_column_int64(stmt, 0),
                    path: String(cString: sqlite3_column_text(stmt, 1)),
                    schedule: SweepSchedule(cadence: cadence,
                                            preferredHour: Int(sqlite3_column_int64(stmt, 3)),
                                            enabled: sqlite3_column_int64(stmt, 4) != 0),
                    mode: mode))
            }
            return out
        }
    }

    public func updateSchedule(path: String, schedule: SweepSchedule, mode: CompressionMode) throws {
        try queue.sync {
            try run("""
                UPDATE watched_directory
                SET cadence = ?, preferred_hour = ?, schedule_enabled = ?, mode = ?
                WHERE path = ?;
                """, [.text(schedule.cadence.rawValue), .int(Int64(schedule.preferredHour)),
                      .int(schedule.enabled ? 1 : 0), .text(mode.rawValue), .text(path)])
        }
    }

    // MARK: - Sweep history

    public struct SweepRun: Sendable, Identifiable {
        public let id: Int64
        public let path: String
        public let startedAt: Date
        public let duration: TimeInterval
        public let filesCompressed: Int
        public let filesFailed: Int
        public let bytesReclaimed: Int64
        public let deferral: SweepDeferral?
        public let error: String?
        public let cancelled: Bool

        /// One line for the history list.
        public var summary: String {
            if let d = deferral { return d.explanation }
            if let e = error { return "Failed — \(e)" }
            if cancelled { return "Stopped after \(filesCompressed) files" }
            if filesCompressed == 0 { return "Nothing had changed" }
            var s = "Compressed \(filesCompressed) file\(filesCompressed == 1 ? "" : "s"), reclaimed \(ByteFormat.short(bytesReclaimed))"
            if filesFailed > 0 { s += " · \(filesFailed) skipped" }
            return s
        }
    }

    @discardableResult
    public func recordSweep(path: String, startedAt: Date, duration: TimeInterval,
                            filesCompressed: Int = 0, filesFailed: Int = 0,
                            bytesReclaimed: Int64 = 0, deferral: SweepDeferral? = nil,
                            error: String? = nil, cancelled: Bool = false) throws -> Int64 {
        try queue.sync {
            try run("""
                INSERT INTO sweep_run
                  (path, started_at, duration, files_compressed, files_failed,
                   bytes_reclaimed, deferral, error, cancelled)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, [.text(path), .real(startedAt.timeIntervalSince1970), .real(duration),
                      .int(Int64(filesCompressed)), .int(Int64(filesFailed)),
                      .int(bytesReclaimed),
                      deferral.map { Value.text($0.rawValue) } ?? .null,
                      error.map { Value.text($0) } ?? .null,
                      .int(cancelled ? 1 : 0)])
            return sqlite3_last_insert_rowid(db)
        }
    }

    public func sweepHistory(path: String, limit: Int = 20) throws -> [SweepRun] {
        try queue.sync {
            var out: [SweepRun] = []
            try query("""
                SELECT id, path, started_at, duration, files_compressed, files_failed,
                       bytes_reclaimed, deferral, error, cancelled
                FROM sweep_run WHERE path = ? ORDER BY started_at DESC LIMIT ?;
                """, [.text(path), .int(Int64(limit))]) { stmt in
                func text(_ i: Int32) -> String? {
                    guard let c = sqlite3_column_text(stmt, i) else { return nil }
                    return String(cString: c)
                }
                out.append(SweepRun(
                    id: sqlite3_column_int64(stmt, 0),
                    path: String(cString: sqlite3_column_text(stmt, 1)),
                    startedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    duration: sqlite3_column_double(stmt, 3),
                    filesCompressed: Int(sqlite3_column_int64(stmt, 4)),
                    filesFailed: Int(sqlite3_column_int64(stmt, 5)),
                    bytesReclaimed: sqlite3_column_int64(stmt, 6),
                    deferral: text(7).flatMap(SweepDeferral.init(rawValue:)),
                    error: text(8),
                    cancelled: sqlite3_column_int64(stmt, 9) != 0))
            }
            return out
        }
    }

    /// When a real (non-deferred) sweep last completed for this path.
    public func lastCompletedSweep(path: String) throws -> Date? {
        try queue.sync {
            var out: Date?
            try query("""
                SELECT started_at FROM sweep_run
                WHERE path = ? AND deferral IS NULL AND error IS NULL
                ORDER BY started_at DESC LIMIT 1;
                """, [.text(path)]) { stmt in
                out = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            }
            return out
        }
    }

    public func watchedDirectories() throws -> [String] {
        try queue.sync {
            var out: [String] = []
            try query("SELECT path FROM watched_directory ORDER BY added_at;") { stmt in
                out.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return out
        }
    }

    // MARK: - Snapshots

    @discardableResult
    public func record(_ result: ScanResult) throws -> Int64 {
        try queue.sync {
            let p = result.progress
            try run("""
                INSERT INTO scan_snapshot
                  (directory_id, path, scanned_at, duration, files, directories,
                   logical_bytes, physical_bytes, compressed_files, compressed_logical,
                   compressed_physical, excluded_files, eligible_files, eligible_logical,
                   hard_link_duplicates, unreadable_entries)
                VALUES
                  ((SELECT id FROM watched_directory WHERE path = ?), ?, ?, ?, ?, ?,
                   ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, [
                    .text(result.root), .text(result.root),
                    .real(Date().timeIntervalSince1970), .real(result.duration),
                    .int(Int64(p.filesSeen)), .int(Int64(p.directoriesSeen)),
                    .int(p.logicalBytes), .int(p.physicalBytes),
                    .int(Int64(p.compressedFiles)), .int(p.compressedLogicalBytes),
                    .int(p.compressedPhysicalBytes), .int(Int64(p.excludedFiles)),
                    .int(Int64(p.eligibleFiles)), .int(p.eligibleLogicalBytes),
                    .int(Int64(result.hardLinkDuplicates)), .int(Int64(result.unreadableEntries)),
                ])
            return sqlite3_last_insert_rowid(db)
        }
    }

    public struct SnapshotSummary: Sendable {
        public let scannedAt: Date
        public let files: Int
        public let logicalBytes: Int64
        public let physicalBytes: Int64
        public let compressedFiles: Int
        public let compressedLogicalBytes: Int64
        public let compressedPhysicalBytes: Int64
        public let eligibleFiles: Int

        public var compressionCoverage: Double {
            files > 0 ? Double(compressedFiles) / Double(files) : 0
        }

        public var reclaimedBytes: Int64 {
            max(0, compressedLogicalBytes - compressedPhysicalBytes)
        }
    }

    public func latestSnapshot(path: String) throws -> SnapshotSummary? {
        try queue.sync {
            var out: SnapshotSummary?
            try query("""
                SELECT scanned_at, files, logical_bytes, physical_bytes, compressed_files,
                       compressed_logical, compressed_physical, eligible_files
                FROM scan_snapshot WHERE path = ? ORDER BY scanned_at DESC, id DESC LIMIT 1;
                """, [.text(path)]) { stmt in
                out = SnapshotSummary(
                    scannedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    files: Int(sqlite3_column_int64(stmt, 1)),
                    logicalBytes: sqlite3_column_int64(stmt, 2),
                    physicalBytes: sqlite3_column_int64(stmt, 3),
                    compressedFiles: Int(sqlite3_column_int64(stmt, 4)),
                    compressedLogicalBytes: sqlite3_column_int64(stmt, 5),
                    compressedPhysicalBytes: sqlite3_column_int64(stmt, 6),
                    eligibleFiles: Int(sqlite3_column_int64(stmt, 7)))
            }
            return out
        }
    }

    /// Oldest-first so callers can draw a timeline without reversing database output.
    public func snapshotHistory(path: String, limit: Int = 90) throws -> [SnapshotSummary] {
        try queue.sync {
            var out: [SnapshotSummary] = []
            try query("""
                SELECT scanned_at, files, logical_bytes, physical_bytes, compressed_files,
                       compressed_logical, compressed_physical, eligible_files
                FROM scan_snapshot WHERE path = ?
                ORDER BY scanned_at DESC, id DESC LIMIT ?;
                """, [.text(path), .int(Int64(limit))]) { stmt in
                out.append(SnapshotSummary(
                    scannedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    files: Int(sqlite3_column_int64(stmt, 1)),
                    logicalBytes: sqlite3_column_int64(stmt, 2),
                    physicalBytes: sqlite3_column_int64(stmt, 3),
                    compressedFiles: Int(sqlite3_column_int64(stmt, 4)),
                    compressedLogicalBytes: sqlite3_column_int64(stmt, 5),
                    compressedPhysicalBytes: sqlite3_column_int64(stmt, 6),
                    eligibleFiles: Int(sqlite3_column_int64(stmt, 7))))
            }
            return out.reversed()
        }
    }

    // MARK: - Thin SQLite wrapper

    public enum Value { case text(String), int(Int64), real(Double), null }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw StoreError.sql(m)
        }
    }

    private func prepare(_ sql: String, _ binds: [Value]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .int(let n):  sqlite3_bind_int64(stmt, idx, n)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .null:        sqlite3_bind_null(stmt, idx)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ binds: [Value] = []) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func query(_ sql: String, _ binds: [Value] = [],
                       _ each: (OpaquePointer?) -> Void) throws {
        let stmt = try prepare(sql, binds)
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { each(stmt) }
    }

    private func scalar(_ sql: String, _ binds: [Value] = []) throws -> Int64 {
        try queue.sync { try scalarLocked(sql, binds) }
    }

    private func scalarLocked(_ sql: String, _ binds: [Value] = []) throws -> Int64 {
        var out: Int64 = 0
        try query(sql, binds) { stmt in out = sqlite3_column_int64(stmt, 0) }
        return out
    }
}
