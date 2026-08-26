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
    private let queue = DispatchQueue(label: "org.pomace.Pomace.Store")

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
        if try scalar("SELECT COUNT(*) FROM schema_version") == 0 {
            try exec("INSERT INTO schema_version (version) VALUES (1);")
        }
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
        public let eligibleFiles: Int
    }

    public func latestSnapshot(path: String) throws -> SnapshotSummary? {
        try queue.sync {
            var out: SnapshotSummary?
            try query("""
                SELECT scanned_at, files, logical_bytes, physical_bytes, compressed_files, eligible_files
                FROM scan_snapshot WHERE path = ? ORDER BY scanned_at DESC LIMIT 1;
                """, [.text(path)]) { stmt in
                out = SnapshotSummary(
                    scannedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    files: Int(sqlite3_column_int64(stmt, 1)),
                    logicalBytes: sqlite3_column_int64(stmt, 2),
                    physicalBytes: sqlite3_column_int64(stmt, 3),
                    compressedFiles: Int(sqlite3_column_int64(stmt, 4)),
                    eligibleFiles: Int(sqlite3_column_int64(stmt, 5)))
            }
            return out
        }
    }

    // MARK: - Thin SQLite wrapper

    public enum Value { case text(String), int(Int64), real(Double) }

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
