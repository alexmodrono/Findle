import Foundation
import SQLite3
import SharedDomain

/// A read-only probe that never creates, migrates or repairs the store being diagnosed.
public enum DatabaseDiagnostics {
    public static func capture(path: String?, siteID: String?) -> DiagnosticDatabaseSnapshot {
        guard let path, path != ":memory:" else { return DiagnosticDatabaseSnapshot() }
        var pointer: OpaquePointer?
        let status = sqlite3_open_v2(path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let pointer { sqlite3_close(pointer) } }
        guard status == SQLITE_OK, let db = pointer else { return failed(status) }
        sqlite3_busy_timeout(db, 250)
        var schema: Int64?
        var seed: Int64?
        var counter: Int64?
        do {
            try execute("BEGIN", db: db)
            defer { try? execute("ROLLBACK", db: db) }
            schema = try scalar("PRAGMA user_version", db: db)
            seed = try scalar("SELECT value FROM system_metadata WHERE key = 'seed_complete'", db: db)
            counter = try scalar("SELECT value FROM system_metadata WHERE key = 'change_counter'", db: db)
            var cursors: [DiagnosticDatabaseSnapshot.CourseCursor] = []
            if let siteID {
                var statement: OpaquePointer?
                let prepared = sqlite3_prepare_v2(db, "SELECT course_id, last_sync_date FROM sync_cursors WHERE site_id = ? ORDER BY course_id", -1, &statement, nil)
                defer { sqlite3_finalize(statement) }
                guard prepared == SQLITE_OK else { throw sqliteError(prepared) }
                let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                sqlite3_bind_text(statement, 1, (siteID as NSString).utf8String, -1, transient)
                var step = sqlite3_step(statement)
                while step == SQLITE_ROW {
                    cursors.append(.init(courseID: Int(sqlite3_column_int64(statement, 0)),
                                         lastSuccess: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))))
                    step = sqlite3_step(statement)
                }
                guard step == SQLITE_DONE else { throw sqliteError(step) }
            }
            return DiagnosticDatabaseSnapshot(schemaVersion: schema.map(Int.init), seedComplete: seed.map { $0 == 1 },
                                              changeCounter: counter, cursors: cursors)
        } catch {
            return DiagnosticDatabaseSnapshot(schemaVersion: schema.map(Int.init), seedComplete: seed.map { $0 == 1 },
                                              changeCounter: counter, failure: DiagnosticFailure(error))
        }
    }

    private static func scalar(_ sql: String, db: OpaquePointer) throws -> Int64? {
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard status == SQLITE_OK else { throw sqliteError(status) }
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw sqliteError(step) }
        return sqlite3_column_int64(statement, 0)
    }

    private static func execute(_ sql: String, db: OpaquePointer) throws {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw sqliteError(status) }
    }

    private static func sqliteError(_ code: Int32) -> NSError { NSError(domain: "SQLite", code: Int(code)) }
    private static func failed(_ code: Int32) -> DiagnosticDatabaseSnapshot {
        DiagnosticDatabaseSnapshot(failure: DiagnosticFailure(sqliteError(code)))
    }
}
