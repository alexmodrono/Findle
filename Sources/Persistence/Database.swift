// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SQLite3
import Darwin
import OSLog
import SharedDomain

// Tells SQLite to make its own copy of the bound data during the bind call,
// so the source buffer's lifetime doesn't have to outlive sqlite3_step. The
// default (nil) is SQLITE_STATIC, which is unsafe when the source is an
// autoreleased NSString.utf8String buffer or a transient Swift String.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Apple SQLite can use an active read-only connection's file descriptor for
/// another connection's OFD write lock, failing with SQLITE_IOERR_LOCK/EBADF.
/// Keep transient read-only probes and writer initialization from overlapping
/// within this process. Normal database operations and teardown stay concurrent;
/// the initialization sidecar separately coordinates migrations across processes.
enum DatabaseConnectionGate {
    static let lock = NSLock()
}

/// An older binary must leave a newer store untouched instead of repairing or
/// downgrading it. This distinct error must not trigger an empty fallback store.
public struct UnsupportedDatabaseSchemaError: Error, LocalizedError, Sendable {
    public let version: Int
    public var errorDescription: String? {
        "This database requires a newer version of Findle (schema \(version)). Open it with that version; the database was left unchanged."
    }
}

/// SQLite database manager for Findle's local persistence.
public final class Database: @unchecked Sendable {
    private static let appGroupIdentifier = BundleIdentifiers.appGroup
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "es.amodrono.findle.persistence.db", qos: .userInitiated)
    private let logger = Logger(subsystem: "es.amodrono.findle.persistence", category: "Database")
    private let path: String
    public var filePath: String { path }

    /// The on-disk path of the shared database inside the App Group container,
    /// built by hand from the user's home directory so a non-sandboxed helper
    /// (the MCP server) can locate it without the App Group entitlement.
    public static var sharedContainerDatabasePath: String {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Group Containers/\(appGroupIdentifier)/Application Support/Findle/findle.db")
            .path
    }

    public static let schemaVersion = 15

    /// Opens the database.
    ///
    /// - Parameter readOnly: when `true`, opens as a pure reader and skips all
    ///   schema creation/migration. Used by the MCP server, a third reader on
    ///   the shared WAL database — the app remains the single writer.
    ///
    ///   The handle is opened `READWRITE` so SQLite can initialize WAL/SHM
    ///   sidecars when the final previous connection removed them. A strict
    ///   `READONLY` connection cannot always initialize those missing files.
    ///   `PRAGMA query_only = ON` prevents SQL writes; schema migrations are
    ///   skipped and committed WAL pages remain visible.
    public init(path: String? = nil, readOnly: Bool = false) throws {
        if let path = path {
            self.path = path
        } else {
            let fm = FileManager.default
            // `NSHomeDirectory()` points at the real home directory even
            // inside the sandbox. Use the resolved user-domain URL so a
            // missing App Group entitlement cannot make sign-in attempt
            // to write outside the app's container.
            let containerAppSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.temporaryDirectory.appendingPathComponent("Findle", isDirectory: true)

            var dbDir: URL?
            if let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
                let preferredAppSupport = groupURL.appendingPathComponent("Application Support", isDirectory: true)
                let legacyAppSupport = groupURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)

                // The system can refuse the App Group container even though the
                // entitlement is present: since macOS 15 a `group.` identifier
                // must also be authorized by the provisioning profile, and a
                // container created by a differently signed build stays locked.
                // Fall back to the app's own container instead of failing sign-in.
                // Only the MCP helper, which looks in the group container, loses
                // access to this copy; the File Provider uses its own database.
                do {
                    try Self.migrateLegacyDatabaseIfNeeded(
                        from: legacyAppSupport,
                        to: preferredAppSupport,
                        fileManager: fm
                    )
                    let groupDBDir = preferredAppSupport.appendingPathComponent("Findle", isDirectory: true)
                    try fm.createDirectory(at: groupDBDir, withIntermediateDirectories: true)
                    dbDir = groupDBDir
                } catch {
                    if error is UnsupportedDatabaseSchemaError || error is FindleError { throw error }
                    Logger(subsystem: "es.amodrono.findle.persistence", category: "Database")
                        .error("App Group container unusable, using the app container instead: \(DiagnosticFailure(error).summary, privacy: .public)")
                }
            }

            // The AppKit host is not sandboxed, so its fallback Application Support
            // directory is shared with other processes. Preserve variant isolation.
            let fallbackName = BundleIdentifiers.isNightly ? "Findle Nightly" : "Findle"
            let resolvedDBDir = dbDir ?? containerAppSupport.appendingPathComponent(fallbackName, isDirectory: true)
            if dbDir == nil {
                try fm.createDirectory(at: resolvedDBDir, withIntermediateDirectories: true)
            }
            self.path = resolvedDBDir.appendingPathComponent("findle.db").path
        }

        // Include the read-only preflight, its statement finalization and the
        // writer's schema/WAL setup in one process-local critical section.
        // FULLMUTEX only protects a single SQLite connection; flock alone does
        // not cover the independent read-only probes in this process.
        DatabaseConnectionGate.lock.lock()
        defer { DatabaseConnectionGate.lock.unlock() }

        // Inspect an existing store without opening a writer. In particular,
        // an older binary must not create tables or switch a future store to WAL.
        let existingStore = self.path != ":memory:" && FileManager.default.fileExists(atPath: self.path)
        if existingStore { try Self.rejectUnsupportedSchema(at: self.path) }
        // BEGIN IMMEDIATE serializes schema writes, but cannot span the later
        // journal-mode change. Coordinate the complete writer initialization
        // across host/extension processes to avoid lock-mode conversion races.
        let initializationLock = !readOnly && self.path != ":memory:"
            ? try Self.lockInitialization(at: self.path) : nil
        defer {
            if let initializationLock {
                flock(initializationLock, LOCK_UN)
                close(initializationLock)
            }
        }
        var dbPointer: OpaquePointer?
        let flags = (readOnly || existingStore)
            ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let status = sqlite3_open_v2(self.path, &dbPointer, flags, nil)
        guard status == SQLITE_OK, let pointer = dbPointer else {
            let message = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            if let dbPointer { sqlite3_close(dbPointer) }
            throw FindleError.databaseError(detail: "Could not open database: \(message)")
        }
        self.db = pointer

        // Wait up to 5s on SQLITE_BUSY before failing. With the File Provider
        // extension reading concurrently under WAL, lock contention is normal
        // and short retries inside SQLite are cheaper than surfacing errors.
        sqlite3_busy_timeout(pointer, 5000)

        do {
            // Repeat after opening: the store may have changed since preflight.
            try queue.sync { try validateSupportedSchemaUnsafe() }
            if readOnly {
                try execute("PRAGMA query_only = ON")
                logger.info("Database opened read-only at \(self.path, privacy: .private)")
                return
            }
            try execute("PRAGMA foreign_keys = ON")
            // Schema creation and upgrades share the same lock and rollback.
            // WAL is enabled only after the supported schema has been accepted.
            try migrateSchema()
            try queue.sync { try enableWALUnsafe() }
            logger.info("Database opened at \(self.path, privacy: .private)")
        } catch {
            sqlite3_close(pointer)
            self.db = nil
            throw error
        }
    }

    private static func lockInitialization(at path: String) throws -> Int32 {
        // Retain the sidecar inode: unlinking a lock file could let the next
        // opener lock a different inode while an existing waiter still holds it.
        let descriptor = open(path + ".initialization-lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var acquired = false
        defer { if !acquired { close(descriptor) } }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw FindleError.databaseError(detail: "The database initialization lock is not a regular private file.")
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw FindleError.databaseError(detail: "Another process is preparing the database. Try again when it finishes.")
            }
            sqlite3_sleep(10)
        }
        acquired = true
        return descriptor
    }

    private func enableWALUnsafe() throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while true {
            try validateSupportedSchemaUnsafe()
            let status = sqlite3_exec(db, "PRAGMA journal_mode = WAL", nil, nil, nil)
            if status == SQLITE_OK {
                // Changing journal mode does not open WAL/SHM until the first
                // read. Prime them while initialization still holds the gate,
                // before a true read-only diagnostic can observe the new mode.
                try validateSupportedSchemaUnsafe()
                return
            }
            guard (status == SQLITE_BUSY || status == SQLITE_LOCKED), DispatchTime.now().uptimeNanoseconds < deadline else {
                throw FindleError.databaseError(detail: "Cannot enable database journaling")
            }
            sqlite3_sleep(10)
        }
    }

    private static func rejectUnsupportedSchema(at path: String) throws {
        // A second opener can create/checkpoint the WAL between our read-only
        // open and first query. Close failed readers before retrying so they do
        // not prevent the winning opener from finishing WAL/SHM initialization.
        func inspect() throws -> (version: Int?, status: Int32) {
            var handle: OpaquePointer?
            let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            defer { if let handle { sqlite3_close(handle) } }
            guard status == SQLITE_OK, let handle else { return (nil, status) }
            sqlite3_busy_timeout(handle, 100)
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(handle, "PRAGMA user_version", -1, &statement, nil)
            defer { sqlite3_finalize(statement) }
            let stepStatus = prepared == SQLITE_OK ? sqlite3_step(statement) : prepared
            if stepStatus == SQLITE_ROW { return (Int(sqlite3_column_int(statement, 0)), stepStatus) }
            if (stepStatus & 0xff) == SQLITE_CANTOPEN,
               !FileManager.default.fileExists(atPath: path + "-wal") {
                // With no committed WAL pages, the main-file header contains
                // the durable version (SQLite file format, offset 60). SQLite
                // rechecks it after opening and under the migration lock.
                // Use SQLite's existing VFS descriptor. Opening and closing a
                // separate POSIX descriptor here would release this process's
                // locks on the same inode, including other SQLite connections.
                var file: UnsafeMutablePointer<sqlite3_file>?
                guard sqlite3_file_control(handle, "main", SQLITE_FCNTL_FILE_POINTER, &file) == SQLITE_OK,
                      let file, let read = file.pointee.pMethods?.pointee.xRead else {
                    return (nil, stepStatus)
                }
                var header = Data(count: 64)
                let headerStatus = header.withUnsafeMutableBytes { read(file, $0.baseAddress, 64, 0) }
                guard headerStatus == SQLITE_OK, header.prefix(16) == Data("SQLite format 3\0".utf8) else {
                    throw FindleError.databaseError(detail: "Cannot read the database schema version")
                }
                let version = Int(header[60..<64].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
                return (version, stepStatus)
            }
            return (nil, stepStatus)
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while true {
            let result = try inspect()
            if let version = result.version {
                guard version <= schemaVersion else { throw UnsupportedDatabaseSchemaError(version: version) }
                return
            }
            let code = result.status & 0xff
            guard [SQLITE_CANTOPEN, SQLITE_BUSY, SQLITE_LOCKED].contains(code),
                  DispatchTime.now().uptimeNanoseconds < deadline else {
                throw FindleError.databaseError(detail: "Cannot read the database schema version (SQLite \(result.status))")
            }
            sqlite3_sleep(10)
        }
    }

    private func validateSupportedSchemaUnsafe() throws {
        let version = try scalarUnsafe("PRAGMA user_version")
        guard version <= Self.schemaVersion else { throw UnsupportedDatabaseSchemaError(version: Int(version)) }
    }

    private func scalarUnsafe(_ sql: String) throws -> Int64 {
        let statement = try prepareStatement(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw FindleError.databaseError(detail: "Failed to read database metadata")
        }
        return sqlite3_column_int64(statement, 0)
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private static func databaseDirectory(in appSupport: URL) -> URL {
        appSupport.appendingPathComponent("Findle", isDirectory: true)
    }

    private static func databaseURL(in appSupport: URL) -> URL {
        databaseDirectory(in: appSupport).appendingPathComponent("findle.db")
    }

    private static func migrateLegacyDatabaseIfNeeded(
        from legacyAppSupport: URL,
        to preferredAppSupport: URL,
        fileManager: FileManager
    ) throws {
        let legacyDatabaseURL = databaseURL(in: legacyAppSupport)
        let preferredDatabaseURL = databaseURL(in: preferredAppSupport)

        guard fileManager.fileExists(atPath: legacyDatabaseURL.path) else { return }
        guard !fileManager.fileExists(atPath: preferredDatabaseURL.path) else { return }

        let preferredDirectory = databaseDirectory(in: preferredAppSupport)
        try fileManager.createDirectory(at: preferredDirectory, withIntermediateDirectories: true)

        let legacy = try Database(path: legacyDatabaseURL.path)
        // Relocation preserves even an unfinished seed. Readiness is checked
        // separately before a provider reset; copying DB/WAL/SHM independently
        // could otherwise publish pages from different database revisions.
        try legacy.writeRecoverySnapshot(to: preferredDatabaseURL, requireComplete: false)
    }

    // MARK: - Schema

    private func createSchemaUnsafe() throws {
        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS sites (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                base_url TEXT NOT NULL,
                supports_web_services INTEGER NOT NULL DEFAULT 0,
                supports_mobile_api INTEGER NOT NULL DEFAULT 0,
                supports_file_download INTEGER NOT NULL DEFAULT 0,
                moodle_version TEXT,
                moodle_release TEXT,
                site_name TEXT,
                created_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
                login_type INTEGER NOT NULL DEFAULT 1,
                launch_url TEXT,
                wwwroot TEXT,
                httpswwwroot TEXT,
                show_login_form INTEGER NOT NULL DEFAULT 1
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS accounts (
                id TEXT PRIMARY KEY,
                site_id TEXT NOT NULL REFERENCES sites(id) ON DELETE CASCADE,
                user_id INTEGER,
                username TEXT,
                full_name TEXT,
                state TEXT NOT NULL DEFAULT 'disconnected',
                last_sync_date REAL,
                created_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS courses (
                id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                short_name TEXT NOT NULL,
                full_name TEXT NOT NULL,
                summary TEXT,
                category_id INTEGER,
                start_date REAL,
                end_date REAL,
                last_accessed REAL,
                visible INTEGER NOT NULL DEFAULT 1,
                subscription_state TEXT NOT NULL DEFAULT 'discovered',
                PRIMARY KEY (id, site_id)
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS course_outlines (
                course_id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                payload TEXT NOT NULL,
                updated_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
                PRIMARY KEY (course_id, site_id)
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY,
                parent_id TEXT,
                site_id TEXT NOT NULL,
                course_id INTEGER NOT NULL,
                remote_id INTEGER NOT NULL,
                filename TEXT NOT NULL,
                is_directory INTEGER NOT NULL DEFAULT 0,
                content_type TEXT,
                file_size INTEGER NOT NULL DEFAULT 0,
                creation_date REAL,
                modification_date REAL,
                sync_state TEXT NOT NULL DEFAULT 'placeholder',
                is_pinned INTEGER NOT NULL DEFAULT 0,
                local_path TEXT,
                remote_url TEXT,
                content_version TEXT,
                tag_data BLOB,
                updated_at INTEGER NOT NULL DEFAULT 0
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS sync_cursors (
                course_id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                last_sync_date REAL NOT NULL,
                last_modified REAL,
                item_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (course_id, site_id)
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS course_tags (
                course_id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                tag_name TEXT NOT NULL,
                tag_color INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (course_id, site_id, tag_name)
            )
        """)

        // MARK: Read-only coursework tracking (deadlines, grades, quizzes)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS assignments (
                id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                course_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                due_date REAL,
                cutoff_date REAL,
                submitted INTEGER NOT NULL DEFAULT 0,
                graded INTEGER NOT NULL DEFAULT 0,
                grade TEXT,
                PRIMARY KEY (id, site_id)
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS grade_items (
                id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                course_id INTEGER NOT NULL,
                item_name TEXT NOT NULL,
                grade TEXT,
                percentage TEXT,
                feedback TEXT,
                PRIMARY KEY (id, site_id, course_id)
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS quizzes (
                id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                course_id INTEGER NOT NULL,
                name TEXT NOT NULL,
                open_date REAL,
                close_date REAL,
                time_limit INTEGER,
                PRIMARY KEY (id, site_id)
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS quiz_attempts (
                id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                quiz_id INTEGER NOT NULL,
                attempt_number INTEGER NOT NULL,
                state TEXT NOT NULL,
                sum_grades REAL,
                start_time REAL,
                finish_time REAL,
                PRIMARY KEY (id, site_id)
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS pending_deletions (
                item_id TEXT PRIMARY KEY,
                site_id TEXT NOT NULL DEFAULT '',
                deleted_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
                deleted_at_counter INTEGER NOT NULL DEFAULT 0
            )
        """)

        try executeUnsafe("""
            CREATE TABLE IF NOT EXISTS system_metadata (
                key TEXT PRIMARY KEY,
                value INTEGER NOT NULL
            )
        """)

        try executeUnsafe("""
            CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parent_id)
        """)

        try executeUnsafe("""
            CREATE INDEX IF NOT EXISTS idx_items_course ON items(course_id, site_id)
        """)

        try executeUnsafe("""
            CREATE INDEX IF NOT EXISTS idx_items_sync_state ON items(sync_state)
        """)

        try executeUnsafe("""
            CREATE INDEX IF NOT EXISTS idx_items_pinned ON items(site_id, is_pinned) WHERE is_pinned = 1
        """)
    }

    /// Upgrades an older schema inside one `BEGIN IMMEDIATE` transaction.
    /// Current stores do not acquire SQLite's writer lock. The version is
    /// rechecked under that lock before changing an older schema, so an
    /// intervening upgrade is never repeated.
    private func migrateSchema() throws {
        try queue.sync {
            // Initialization is already serialized by the sidecar lock. A
            // current schema needs no write transaction: taking one can race
            // normal writers/connection teardown even though nothing migrates.
            let version = try scalarUnsafe("PRAGMA user_version")
            guard version <= Self.schemaVersion else {
                throw UnsupportedDatabaseSchemaError(version: Int(version))
            }
            guard version < Self.schemaVersion else { return }
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                try validateSupportedSchemaUnsafe()
                if try scalarUnsafe("PRAGMA user_version") < Self.schemaVersion {
                    try createSchemaUnsafe()
                    try migrateSchemaInTransaction()
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    /// Body of `migrateSchema`. Only call from within the `queue.sync` block and
    /// write transaction opened by `migrateSchema`.
    private func migrateSchemaInTransaction() throws {
        // Read the current user_version pragma. This runs under the write lock,
        // so it reflects any migration another process has already committed.
        let currentVersion = try scalarUnsafe("PRAGMA user_version")
        try validateSupportedSchemaUnsafe()
        guard currentVersion < Self.schemaVersion else { return }

        // Seed rows for system_metadata. They live here rather than in
        // createSchema() so that everything which writes runs in the transaction.
        try executeUnsafe("INSERT OR IGNORE INTO system_metadata (key, value) VALUES ('change_counter', 0)")
        try executeUnsafe("INSERT OR IGNORE INTO system_metadata (key, value) VALUES ('seed_complete', 0)")

        if currentVersion < 2 {
            // v1 -> v2: add login_type and launch_url columns to sites.
            let columns = try existingColumns(table: "sites")
            if !columns.contains("login_type") {
                try executeUnsafe("ALTER TABLE sites ADD COLUMN login_type INTEGER NOT NULL DEFAULT 1")
            }
            if !columns.contains("launch_url") {
                try executeUnsafe("ALTER TABLE sites ADD COLUMN launch_url TEXT")
            }
            logger.info("Migrated database schema to version 2")
        }

        if currentVersion < 3 {
            // v2 -> v3: add wwwroot, httpswwwroot, show_login_form columns to sites.
            let columns = try existingColumns(table: "sites")
            if !columns.contains("wwwroot") {
                try executeUnsafe("ALTER TABLE sites ADD COLUMN wwwroot TEXT")
            }
            if !columns.contains("httpswwwroot") {
                try executeUnsafe("ALTER TABLE sites ADD COLUMN httpswwwroot TEXT")
            }
            if !columns.contains("show_login_form") {
                try executeUnsafe("ALTER TABLE sites ADD COLUMN show_login_form INTEGER NOT NULL DEFAULT 1")
            }
            logger.info("Migrated database schema to version 3")
        }

        if currentVersion < 4 {
            let courseColumns = try existingColumns(table: "courses")
            if !courseColumns.contains("custom_folder_name") {
                try executeUnsafe("ALTER TABLE courses ADD COLUMN custom_folder_name TEXT")
            }

            let itemColumns = try existingColumns(table: "items")
            if !itemColumns.contains("tag_data") {
                try executeUnsafe("ALTER TABLE items ADD COLUMN tag_data BLOB")
            }

            logger.info("Migrated database schema to version 4")
        }

        if currentVersion < 5 {
            // Fix tag color indices: old values had red=7, orange=6.
            // Correct values: red=6, orange=7. Swap them.
            try executeUnsafe("UPDATE course_tags SET tag_color = -1 WHERE tag_color = 6")
            try executeUnsafe("UPDATE course_tags SET tag_color = 6 WHERE tag_color = 7")
            try executeUnsafe("UPDATE course_tags SET tag_color = 7 WHERE tag_color = -1")
            logger.info("Migrated database schema to version 5 (fixed tag colors)")
        }

        if currentVersion < 6 {
            // v5 -> v6: pending_deletions table created in createSchema().
            logger.info("Migrated database schema to version 6 (pending deletions)")
        }

        if currentVersion < 7 {
            let courseColumns = try existingColumns(table: "courses")
            if !courseColumns.contains("custom_icon_name") {
                try executeUnsafe("ALTER TABLE courses ADD COLUMN custom_icon_name TEXT")
            }
            logger.info("Migrated database schema to version 7 (custom course icons)")
        }

        if currentVersion < 8 {
            let itemColumns = try existingColumns(table: "items")
            if !itemColumns.contains("is_local") {
                try executeUnsafe("ALTER TABLE items ADD COLUMN is_local INTEGER NOT NULL DEFAULT 0")
            }
            logger.info("Migrated database schema to version 8 (local items)")
        }

        if currentVersion < 9 {
            // Regenerate all tagData blobs: previously used NSKeyedArchiver encoding
            // which Finder doesn't correctly interpret. Now uses PropertyListSerialization
            // (binary plist) which matches the com.apple.metadata:_kMDItemUserTags format.
            try regenerateAllTagData()
            logger.info("Migrated database schema to version 9 (fixed tag data encoding)")
        }

        if currentVersion < 10 {
            // pending_deletions originally allowed duplicate item_id rows, so INSERT OR
            // IGNORE could not dedupe and the table grew unbounded on repeated syncs.
            // Rebuild it with item_id as PRIMARY KEY.
            try executeUnsafe("DROP TABLE IF EXISTS pending_deletions_new")
            try executeUnsafe("""
                CREATE TABLE pending_deletions_new (
                    item_id TEXT PRIMARY KEY,
                    deleted_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
                )
            """)
            try executeUnsafe("INSERT OR IGNORE INTO pending_deletions_new SELECT item_id, deleted_at FROM pending_deletions")
            try executeUnsafe("DROP TABLE pending_deletions")
            try executeUnsafe("ALTER TABLE pending_deletions_new RENAME TO pending_deletions")
            logger.info("Migrated database schema to version 10 (pending_deletions dedupe)")
        }

        if currentVersion < 11 {
            // Add a monotonic change counter so the File Provider extension can
            // do incremental change enumeration instead of re-emitting every
            // item on every poll. The counter is bumped by triggers on writes
            // to items and pending_deletions; the value at write time is
            // stamped onto each row so enumerateChanges can filter.
            let itemColumns = try existingColumns(table: "items")
            if !itemColumns.contains("updated_at") {
                try executeUnsafe("ALTER TABLE items ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0")
            }
            let pendingColumns = try existingColumns(table: "pending_deletions")
            if !pendingColumns.contains("deleted_at_counter") {
                try executeUnsafe("ALTER TABLE pending_deletions ADD COLUMN deleted_at_counter INTEGER NOT NULL DEFAULT 0")
            }
            try executeUnsafe("""
                CREATE TABLE IF NOT EXISTS system_metadata (
                    key TEXT PRIMARY KEY,
                    value INTEGER NOT NULL
                )
            """)
            try executeUnsafe("INSERT OR IGNORE INTO system_metadata (key, value) VALUES ('change_counter', 0)")

            // Seed updated_at for existing items so they're treated as having
            // changed once at migration time, and advance the counter past
            // every existing row so future writes get unique values. Same for
            // pre-existing pending_deletions rows.
            try executeUnsafe("UPDATE items SET updated_at = rowid WHERE updated_at = 0")
            try executeUnsafe("UPDATE pending_deletions SET deleted_at_counter = (SELECT COALESCE(MAX(updated_at), 0) FROM items) + rowid WHERE deleted_at_counter = 0")
            try executeUnsafe("""
                UPDATE system_metadata
                SET value = (
                    SELECT MAX(c) FROM (
                        SELECT COALESCE(MAX(updated_at), 0) AS c FROM items
                        UNION ALL
                        SELECT COALESCE(MAX(deleted_at_counter), 0) FROM pending_deletions
                    )
                )
                WHERE key = 'change_counter'
            """)

            try executeUnsafe("CREATE INDEX IF NOT EXISTS idx_items_updated_at ON items(updated_at)")
            try executeUnsafe("CREATE INDEX IF NOT EXISTS idx_pending_deletions_counter ON pending_deletions(deleted_at_counter)")
            try executeUnsafe("""
                CREATE TRIGGER IF NOT EXISTS items_bump_after_insert
                AFTER INSERT ON items
                WHEN NEW.updated_at = 0
                BEGIN
                    UPDATE system_metadata SET value = value + 1 WHERE key = 'change_counter';
                    UPDATE items SET updated_at = (SELECT value FROM system_metadata WHERE key = 'change_counter') WHERE id = NEW.id;
                END
            """)
            try executeUnsafe("""
                CREATE TRIGGER IF NOT EXISTS items_bump_after_update
                AFTER UPDATE OF parent_id, filename, file_size, sync_state, is_pinned, local_path, remote_url, content_version, tag_data, is_local, modification_date
                ON items
                BEGIN
                    UPDATE system_metadata SET value = value + 1 WHERE key = 'change_counter';
                    UPDATE items SET updated_at = (SELECT value FROM system_metadata WHERE key = 'change_counter') WHERE id = NEW.id;
                END
            """)
            try executeUnsafe("""
                CREATE TRIGGER IF NOT EXISTS pending_deletions_bump_after_insert
                AFTER INSERT ON pending_deletions
                WHEN NEW.deleted_at_counter = 0
                BEGIN
                    UPDATE system_metadata SET value = value + 1 WHERE key = 'change_counter';
                    UPDATE pending_deletions SET deleted_at_counter = (SELECT value FROM system_metadata WHERE key = 'change_counter') WHERE item_id = NEW.item_id;
                END
            """)
            logger.info("Migrated database schema to version 11 (monotonic change counter)")
        }

        if currentVersion < 12 {
            // v11 -> v12: add the Moodle overview/banner image URL used as a
            // gallery cover. Nullable; populated on the next course fetch.
            let courseColumns = try existingColumns(table: "courses")
            if !courseColumns.contains("image_url") {
                try executeUnsafe("ALTER TABLE courses ADD COLUMN image_url TEXT")
            }
            logger.info("Migrated database schema to version 12 (course cover images)")
        }

        if currentVersion < 13 {
            // v12 -> v13: read-only coursework tracking tables (assignments,
            // grade_items, quizzes, quiz_attempts). Created in createSchema()
            // with IF NOT EXISTS, so this is just the version marker.
            logger.info("Migrated database schema to version 13 (coursework tracking)")
        }

        if currentVersion < 14 {
            // v13 -> v14: compact, token-safe Moodle activity outlines. The
            // table is created above for new databases and backfilled during
            // the next course sync for existing installations.
            logger.info("Migrated database schema to version 14 (course outlines)")
        }

        if currentVersion < 15 {
            // v14 -> v15: associate deletion tombstones with their File
            // Provider domain so one site's enumerator cannot receive another
            // site's deleted identifiers. Existing rows retain an empty site
            // ID and are intentionally excluded from site-scoped queries.
            let pendingColumns = try existingColumns(table: "pending_deletions")
            if !pendingColumns.contains("site_id") {
                try executeUnsafe("ALTER TABLE pending_deletions ADD COLUMN site_id TEXT NOT NULL DEFAULT ''")
            }
            // Remote item identifiers include the site UUID. Recover ownership
            // for legacy tombstones before site-scoped enumerators start using
            // the new column; ambiguous rows remain empty and are not emitted
            // into an unrelated domain.
            try executeUnsafe("""
                UPDATE pending_deletions
                SET site_id = (
                    SELECT sites.id
                    FROM sites
                    WHERE instr(pending_deletions.item_id, 'course-' || sites.id || '-') = 1
                       OR instr(pending_deletions.item_id, 'section-' || sites.id || '-') = 1
                       OR instr(pending_deletions.item_id, 'file-' || sites.id || '-') = 1
                       OR instr(pending_deletions.item_id, 'folder-' || sites.id || '-') = 1
                       OR instr(pending_deletions.item_id, 'url-' || sites.id || '-') = 1
                       OR instr(pending_deletions.item_id, 'page-' || sites.id || '-') = 1
                    LIMIT 1
                )
                WHERE site_id = ''
            """)
            logger.info("Migrated database schema to version 15 (site-scoped tombstones)")
        }

        // Databases created before the seed marker was introduced were already
        // authoritative app databases. Promote only those legacy databases
        // that contain a session; a partial v14+ snapshot must remain false.
        if currentVersion < 14 {
            try executeUnsafe("""
                UPDATE system_metadata
                SET value = 1
                WHERE key = 'seed_complete'
                  AND EXISTS (SELECT 1 FROM sites)
                  AND EXISTS (SELECT 1 FROM accounts WHERE state LIKE 'authenticated%')
            """)
        }

        try executeUnsafe("PRAGMA user_version = \(Self.schemaVersion)")
    }

    /// Regenerate tag_data blobs for all course items from course_tags table.
    /// Only call from within a `queue.sync` block.
    private func regenerateAllTagData() throws {
        // Find all distinct (course_id, site_id) pairs with tags
        let keysStmt = try prepareStatement("SELECT DISTINCT course_id, site_id FROM course_tags")
        defer { sqlite3_finalize(keysStmt) }

        var courseKeys: [(courseID: Int, siteID: String)] = []
        while sqlite3_step(keysStmt) == SQLITE_ROW {
            let courseID = Int(sqlite3_column_int64(keysStmt, 0))
            let siteID = String(cString: sqlite3_column_text(keysStmt, 1))
            courseKeys.append((courseID, siteID))
        }

        for key in courseKeys {
            let tagStmt = try prepareStatement(
                "SELECT tag_name, tag_color FROM course_tags WHERE course_id = ? AND site_id = ? ORDER BY tag_name"
            )
            defer { sqlite3_finalize(tagStmt) }
            sqlite3_bind_int64(tagStmt, 1, Int64(key.courseID))
            sqlite3_bind_text(tagStmt, 2, (key.siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)

            var tags: [FinderTag] = []
            while sqlite3_step(tagStmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(tagStmt, 0))
                let colorRaw = Int(sqlite3_column_int(tagStmt, 1))
                let color = FinderTag.Color(rawValue: colorRaw) ?? .none
                tags.append(FinderTag(name: name, color: color))
            }

            let itemID = "course-\(key.siteID)-\(key.courseID)"
            let tagData = FinderTag.tagData(from: tags)

            let updateStmt = try prepareStatement("UPDATE items SET tag_data = ? WHERE id = ?")
            defer { sqlite3_finalize(updateStmt) }
            if let td = tagData {
                sqlite3_bind_blob(updateStmt, 1, (td as NSData).bytes, Int32(td.count), SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(updateStmt, 1)
            }
            sqlite3_bind_text(updateStmt, 2, (itemID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(updateStmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to regenerate tag data for \(itemID)")
            }
        }
    }

    /// Only call from within a `queue.sync` block.
    private func existingColumns(table: String) throws -> Set<String> {
        let stmt = try prepareStatement("PRAGMA table_info(\(table))")
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let namePtr = sqlite3_column_text(stmt, 1) {
                names.insert(String(cString: namePtr))
            }
        }
        return names
    }

    // MARK: - Execution

    func execute(_ sql: String) throws {
        try queue.sync {
            try executeUnsafe(sql)
        }
    }

    /// Execute SQL without acquiring the queue. Only call from within a `queue.sync` block.
    private func executeUnsafe(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        if status != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            let operation = sql.trimmingCharacters(in: .whitespacesAndNewlines).prefix { !$0.isWhitespace }
            let known = ["BEGIN", "COMMIT", "ROLLBACK", "CREATE", "ALTER", "DROP", "PRAGMA", "INSERT", "UPDATE", "DELETE", "ATTACH", "DETACH"]
            let label = known.contains(String(operation)) ? String(operation) : "statement"
            throw FindleError.databaseError(detail: "\(label) failed (SQLite \(sqlite3_extended_errcode(db))): \(message)")
        }
    }

    /// Prepare a SQLite statement. Only call from within a `queue.sync` block.
    private func prepareStatement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard status == SQLITE_OK, let statement = stmt else {
            let message = String(cString: sqlite3_errmsg(db))
            throw FindleError.databaseError(detail: "Prepare failed: \(message)")
        }
        return statement
    }
}

// MARK: - Site Operations

extension Database {
    public func saveSite(_ site: MoodleSite) throws {
        let sql = """
            INSERT INTO sites (id, display_name, base_url, supports_web_services,
                supports_mobile_api, supports_file_download, moodle_version, moodle_release, site_name,
                login_type, launch_url, wwwroot, httpswwwroot, show_login_form)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name, base_url = excluded.base_url,
                supports_web_services = excluded.supports_web_services,
                supports_mobile_api = excluded.supports_mobile_api,
                supports_file_download = excluded.supports_file_download,
                moodle_version = excluded.moodle_version, moodle_release = excluded.moodle_release,
                site_name = excluded.site_name, login_type = excluded.login_type,
                launch_url = excluded.launch_url, wwwroot = excluded.wwwroot,
                httpswwwroot = excluded.httpswwwroot, show_login_form = excluded.show_login_form
        """
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (site.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (site.displayName as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (site.baseURL.absoluteString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, site.capabilities.supportsWebServices ? 1 : 0)
            sqlite3_bind_int(stmt, 5, site.capabilities.supportsMobileAPI ? 1 : 0)
            sqlite3_bind_int(stmt, 6, site.capabilities.supportsFileDownload ? 1 : 0)
            if let v = site.capabilities.moodleVersion { sqlite3_bind_text(stmt, 7, (v as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            if let r = site.capabilities.moodleRelease { sqlite3_bind_text(stmt, 8, (r as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            if let n = site.capabilities.siteName { sqlite3_bind_text(stmt, 9, (n as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 10, Int32(site.capabilities.loginType.rawValue))
            if let l = site.capabilities.launchURL { sqlite3_bind_text(stmt, 11, (l as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            if let w = site.capabilities.wwwroot { sqlite3_bind_text(stmt, 12, (w as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            if let h = site.capabilities.httpswwwroot { sqlite3_bind_text(stmt, 13, (h as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int(stmt, 14, site.capabilities.showLoginForm ? 1 : 0)

            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to save site: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    public func fetchSite(id: String) throws -> MoodleSite? {
        let sql = """
            SELECT id, display_name, base_url, supports_web_services, supports_mobile_api,
                   supports_file_download, moodle_version, moodle_release, site_name,
                   created_at, login_type, launch_url, wwwroot, httpswwwroot, show_login_form
            FROM sites WHERE id = ?
        """
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            let loginTypeRaw = Int(sqlite3_column_int(stmt, 10))
            let loginType = SiteLoginType(rawValue: loginTypeRaw) ?? .app

            // A malformed base_url in the row must surface as an error, not a crash.
            let baseURLString = String(cString: sqlite3_column_text(stmt, 2))
            guard let baseURL = URL(string: baseURLString) else {
                throw FindleError.databaseError(detail: "Stored base URL for site \(id) is invalid")
            }

            return MoodleSite(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                displayName: String(cString: sqlite3_column_text(stmt, 1)),
                baseURL: baseURL,
                capabilities: SiteCapabilities(
                    supportsWebServices: sqlite3_column_int(stmt, 3) == 1,
                    supportsMobileAPI: sqlite3_column_int(stmt, 4) == 1,
                    supportsFileDownload: sqlite3_column_int(stmt, 5) == 1,
                    moodleVersion: sqlite3_column_text(stmt, 6).map { String(cString: $0) },
                    moodleRelease: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
                    siteName: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
                    loginType: loginType,
                    launchURL: sqlite3_column_text(stmt, 11).map { String(cString: $0) },
                    wwwroot: sqlite3_column_text(stmt, 12).map { String(cString: $0) },
                    httpswwwroot: sqlite3_column_text(stmt, 13).map { String(cString: $0) },
                    showLoginForm: sqlite3_column_int(stmt, 14) == 1
                )
            )
        }
    }
}

// MARK: - Account Operations

extension Database {
    public func saveAccount(_ account: Account) throws {
        let sql = """
            INSERT OR REPLACE INTO accounts (id, site_id, user_id, state, last_sync_date, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (account.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (account.siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let uid = account.userID { sqlite3_bind_int64(stmt, 3, Int64(uid)) }
            sqlite3_bind_text(stmt, 4, (String(describing: account.state) as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let sync = account.lastSyncDate { sqlite3_bind_double(stmt, 5, sync.timeIntervalSince1970) }
            sqlite3_bind_double(stmt, 6, account.createdAt.timeIntervalSince1970)

            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to save account")
            }
        }
    }

    public func fetchAccounts() throws -> [Account] {
        let sql = "SELECT id, site_id, user_id, state, last_sync_date, created_at FROM accounts"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            var accounts: [Account] = []
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let siteID = String(cString: sqlite3_column_text(stmt, 1))
                let userID = sqlite3_column_type(stmt, 2) != SQLITE_NULL ? Int(sqlite3_column_int64(stmt, 2)) : nil
                let stateStr = String(cString: sqlite3_column_text(stmt, 3))
                let lastSync = sqlite3_column_type(stmt, 4) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)) : nil
                let created = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))

                let state: AccountState
                if stateStr.contains("authenticated") {
                    state = .authenticated(userID: userID ?? 0)
                } else if stateStr.contains("expired") {
                    state = .expired
                } else {
                    state = .disconnected
                }

                accounts.append(Account(id: id, siteID: siteID, userID: userID, state: state, lastSyncDate: lastSync, createdAt: created))
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw FindleError.databaseError(detail: "Failed to read accounts") }
            return accounts
        }
    }

    public func deleteAccount(id: String) throws {
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                let deleteItems = try prepareStatement("DELETE FROM items WHERE site_id IN (SELECT site_id FROM accounts WHERE id = ?)")
                defer { sqlite3_finalize(deleteItems) }
                sqlite3_bind_text(deleteItems, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(deleteItems) == SQLITE_DONE else {
                    throw FindleError.databaseError(detail: "Failed to delete account items: \(String(cString: sqlite3_errmsg(db)))")
                }

                let deleteAccount = try prepareStatement("DELETE FROM accounts WHERE id = ?")
                defer { sqlite3_finalize(deleteAccount) }
                sqlite3_bind_text(deleteAccount, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(deleteAccount) == SQLITE_DONE else {
                    throw FindleError.databaseError(detail: "Failed to delete account: \(String(cString: sqlite3_errmsg(db)))")
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }
}

// MARK: - Course Operations

extension Database {
    public func saveCourses(_ courses: [MoodleCourse]) throws {
        // Use INSERT ... ON CONFLICT to preserve user-set custom_folder_name, custom_icon_name, and subscription_state
        let sql = """
            INSERT INTO courses (id, site_id, short_name, full_name, summary,
                category_id, start_date, end_date, last_accessed, visible, subscription_state,
                custom_folder_name, custom_icon_name, image_url)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id, site_id) DO UPDATE SET
                short_name = excluded.short_name,
                full_name = excluded.full_name,
                summary = excluded.summary,
                category_id = excluded.category_id,
                start_date = excluded.start_date,
                end_date = excluded.end_date,
                last_accessed = excluded.last_accessed,
                visible = excluded.visible,
                subscription_state = courses.subscription_state,
                custom_folder_name = COALESCE(courses.custom_folder_name, excluded.custom_folder_name),
                custom_icon_name = COALESCE(courses.custom_icon_name, excluded.custom_icon_name),
                image_url = excluded.image_url
        """
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                for course in courses {
                    let stmt = try prepareStatement(sql)
                    defer { sqlite3_finalize(stmt) }

                    sqlite3_bind_int64(stmt, 1, Int64(course.id))
                    sqlite3_bind_text(stmt, 2, (course.siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, (course.shortName as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 4, (course.fullName as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    if let s = course.summary { sqlite3_bind_text(stmt, 5, (s as NSString).utf8String, -1, SQLITE_TRANSIENT) }
                    if let c = course.categoryID { sqlite3_bind_int64(stmt, 6, Int64(c)) }
                    if let d = course.startDate { sqlite3_bind_double(stmt, 7, d.timeIntervalSince1970) }
                    if let d = course.endDate { sqlite3_bind_double(stmt, 8, d.timeIntervalSince1970) }
                    if let d = course.lastAccessed { sqlite3_bind_double(stmt, 9, d.timeIntervalSince1970) }
                    sqlite3_bind_int(stmt, 10, course.visible ? 1 : 0)
                    let subscriptionState = course.isSyncEnabled
                        ? CourseSubscriptionState.discovered.rawValue
                        : CourseSubscriptionState.unsubscribed.rawValue
                    sqlite3_bind_text(stmt, 11, (subscriptionState as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    if let cfn = course.customFolderName {
                        sqlite3_bind_text(stmt, 12, (cfn as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(stmt, 12)
                    }
                    if let cin = course.customIconName {
                        sqlite3_bind_text(stmt, 13, (cin as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(stmt, 13)
                    }
                    if let imageURL = course.imageURL {
                        sqlite3_bind_text(stmt, 14, (imageURL.absoluteString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    } else {
                        sqlite3_bind_null(stmt, 14)
                    }

                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw FindleError.databaseError(detail: "saveCourses step failed: \(String(cString: sqlite3_errmsg(db)))")
                    }
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    public func fetchCourses(siteID: String) throws -> [MoodleCourse] {
        let sql = "SELECT * FROM courses WHERE site_id = ? ORDER BY full_name"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)

            var courses: [MoodleCourse] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                // Column 10 = subscription_state, Column 11 = custom_folder_name, Column 12 = custom_icon_name
                let colCount = sqlite3_column_count(stmt)

                let subscriptionState: String = {
                    guard sqlite3_column_type(stmt, 10) != SQLITE_NULL else { return "discovered" }
                    return sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? "discovered"
                }()

                let customFolderName: String? = {
                    guard colCount > 11, sqlite3_column_type(stmt, 11) != SQLITE_NULL else { return nil }
                    return sqlite3_column_text(stmt, 11).map { String(cString: $0) }
                }()

                let customIconName: String? = {
                    guard colCount > 12, sqlite3_column_type(stmt, 12) != SQLITE_NULL else { return nil }
                    return sqlite3_column_text(stmt, 12).map { String(cString: $0) }
                }()

                let imageURL: URL? = {
                    guard colCount > 13, sqlite3_column_type(stmt, 13) != SQLITE_NULL else { return nil }
                    return sqlite3_column_text(stmt, 13).map { String(cString: $0) }.flatMap { URL(string: $0) }
                }()

                courses.append(MoodleCourse(
                    id: Int(sqlite3_column_int64(stmt, 0)),
                    shortName: String(cString: sqlite3_column_text(stmt, 2)),
                    fullName: String(cString: sqlite3_column_text(stmt, 3)),
                    summary: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    categoryID: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int64(stmt, 5)) : nil,
                    startDate: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)) : nil,
                    endDate: sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)) : nil,
                    lastAccessed: sqlite3_column_type(stmt, 8) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)) : nil,
                    visible: sqlite3_column_int(stmt, 9) == 1,
                    siteID: siteID,
                    customFolderName: customFolderName,
                    customIconName: customIconName,
                    isSyncEnabled: subscriptionState != CourseSubscriptionState.unsubscribed.rawValue,
                    imageURL: imageURL
                ))
            }
            return courses
        }
    }

    public func updateCourseSubscription(courseID: Int, siteID: String, state: CourseSubscriptionState) throws {
        let sql = "UPDATE courses SET subscription_state = ? WHERE id = ? AND site_id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (state.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 2, Int32(courseID))
            sqlite3_bind_text(stmt, 3, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to update course subscription")
            }
        }
    }

    public func updateCourseCustomFolderName(courseID: Int, siteID: String, customName: String?) throws {
        let sql = "UPDATE courses SET custom_folder_name = ? WHERE id = ? AND site_id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            if let name = customName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_int64(stmt, 2, Int64(courseID))
            sqlite3_bind_text(stmt, 3, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)

            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to update custom folder name")
            }
        }
    }
    public func updateCourseCustomIconName(courseID: Int, siteID: String, iconName: String?) throws {
        let sql = "UPDATE courses SET custom_icon_name = ? WHERE id = ? AND site_id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            if let name = iconName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_int64(stmt, 2, Int64(courseID))
            sqlite3_bind_text(stmt, 3, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)

            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to update custom icon name")
            }
        }
    }
}

// MARK: - Verified Recovery Snapshots

extension Database {
    /// A reset may remove the domain only when its live database is the source
    /// being preserved, or the domain has no saved state yet. A bootstrap copy
    /// cannot establish the chronology of a different nonempty provider store.
    public func verifyProviderResetSource(at providerDatabaseURL: URL) throws {
        func verifyCurrentFile() throws {
            try queue.sync {
                try validateSupportedSchemaUnsafe()
                var moved: Int32 = 0
                let status = sqlite3_file_control(db, "main", SQLITE_FCNTL_HAS_MOVED, &moved)
                guard status == SQLITE_OK, moved == 0 else {
                    throw FindleError.databaseError(detail: "The active Finder database was replaced. Relaunch Findle before resetting; both copies were kept.")
                }
            }
        }
        try verifyCurrentFile()
        var providerInfo = stat()
        if lstat(providerDatabaseURL.path, &providerInfo) != 0 {
            // Unknown/unreadable state must not be mistaken for an empty domain.
            guard errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return
        }
        guard (providerInfo.st_mode & S_IFMT) == S_IFREG else {
            throw FindleError.databaseError(detail: "Finder's database path is not a regular file. Reset was stopped; the existing state was kept.")
        }
        // Inspect through a new reader, even for the same path: the retained
        // handle may refer to a retired inode or the domain may have been upgraded.
        let provider = try Database(path: providerDatabaseURL.path, readOnly: true)
        let sourcePath = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().standardizedFileURL.path
        let providerPath = providerDatabaseURL.resolvingSymlinksInPath().standardizedFileURL.path
        if sourcePath == providerPath {
            try verifyCurrentFile()
            return
        }
        try provider.queue.sync {
            try provider.executeUnsafe("BEGIN DEFERRED TRANSACTION")
            defer { try? provider.executeUnsafe("ROLLBACK") }
            try provider.verifyRecoveryStateUnsafe(requireComplete: false)
            let tables = ["sites", "accounts", "courses", "course_tags", "course_outlines", "items",
                          "sync_cursors", "assignments", "grade_items", "quizzes", "quiz_attempts", "pending_deletions"]
            let hasSavedRows = try tables.contains { table in
                try provider.scalarUnsafe("SELECT EXISTS(SELECT 1 FROM \(table) LIMIT 1)") != 0
            }
            let counter = try provider.scalarUnsafe("SELECT value FROM system_metadata WHERE key = 'change_counter'")
            guard !hasSavedRows, counter == 0 else {
                throw FindleError.databaseError(detail: "Finder has a separate database with saved changes. Relaunch Findle to reconnect before resetting; both copies were kept.")
            }
        }
    }

    /// Write a complete SQLite snapshot to a new path. The backup API includes
    /// committed WAL pages; the live file and its sidecars are never copied apart.
    /// A failed or interrupted snapshot cannot replace an existing recovery copy.
    public func writeRecoverySnapshot(to destination: URL, requireComplete: Bool = true) throws {
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".findle-recovery-\(UUID().uuidString).db")
        let descriptor = open(staging.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(descriptor)
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: staging.path + suffix)
            }
        }
        try queue.sync {
            try executeUnsafe("BEGIN DEFERRED TRANSACTION")
            defer { try? executeUnsafe("ROLLBACK") }
            try verifyRecoveryStateUnsafe(requireComplete: requireComplete)
            var destinationHandle: OpaquePointer?
            guard sqlite3_open_v2(staging.path, &destinationHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let destinationHandle else {
                if let destinationHandle { sqlite3_close(destinationHandle) }
                throw FindleError.databaseError(detail: "Cannot open the recovery snapshot")
            }
            defer { sqlite3_close(destinationHandle) }
            sqlite3_busy_timeout(destinationHandle, 5000)
            guard let backup = sqlite3_backup_init(destinationHandle, "main", db, "main") else {
                throw FindleError.databaseError(detail: "Cannot start the recovery snapshot")
            }
            let step = sqlite3_backup_step(backup, -1)
            let finish = sqlite3_backup_finish(backup)
            guard step == SQLITE_DONE, finish == SQLITE_OK else {
                throw FindleError.databaseError(detail: "The database is busy or could not be copied. Recovery was not started.")
            }
            // Publish a self-contained file, with no WAL required beside it.
            guard sqlite3_exec(destinationHandle, "PRAGMA journal_mode = DELETE", nil, nil, nil) == SQLITE_OK else {
                throw FindleError.databaseError(detail: "Cannot finish the recovery snapshot")
            }
        }
        let verification = try Database(path: staging.path, readOnly: true)
        try verification.queue.sync { try verification.verifyRecoveryStateUnsafe(requireComplete: requireComplete) }
        try Self.synchronizeRecoveryFile(staging)
        // moveItem refuses an existing destination instead of overwriting it.
        try FileManager.default.moveItem(at: staging, to: destination)
        try Self.synchronizeRecoveryFile(parent)
    }

    /// Check integrity, schema, completion, and counter consistency in one view.
    public func verifyCompleteRecoveryState() throws {
        try queue.sync {
            try executeUnsafe("BEGIN DEFERRED TRANSACTION")
            defer { try? executeUnsafe("ROLLBACK") }
            try verifyRecoveryStateUnsafe()
        }
    }

    /// Replace a supported destination from a verified recovery file in one
    /// transaction. Existing readers retain their old snapshot until commit.
    /// Refuse a newer destination; recovery never rolls it back silently.
    public func restoreRecoverySnapshot(from snapshot: URL, resetRemoteContent: Bool = false) throws {
        guard snapshot.resolvingSymlinksInPath().standardizedFileURL.path !=
                URL(fileURLWithPath: filePath).resolvingSymlinksInPath().standardizedFileURL.path else {
            throw FindleError.databaseError(detail: "A database cannot restore itself")
        }
        let verification = try Database(path: snapshot.path, readOnly: true)
        try verification.verifyCompleteRecoveryState()
        try queue.sync {
            let attach = try prepareStatement("ATTACH DATABASE ? AS recovery")
            sqlite3_bind_text(attach, 1, (snapshot.path as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let attached = sqlite3_step(attach)
            sqlite3_finalize(attach)
            guard attached == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Cannot read the recovery snapshot")
            }
            defer { try? executeUnsafe("DETACH DATABASE recovery") }
            try transactionUnsafe {
                try validateSupportedSchemaUnsafe()
                try verifyRecoveryStateUnsafe(schema: "recovery")
                let destinationCounter = try scalarUnsafe("SELECT value FROM main.system_metadata WHERE key = 'change_counter'")
                let sourceCounter = try scalarUnsafe("SELECT value FROM recovery.system_metadata WHERE key = 'change_counter'")
                guard destinationCounter <= sourceCounter else {
                    throw FindleError.databaseError(detail: "The destination contains newer changes. Its data was kept; recovery was not applied.")
                }
                let tables = ["sites", "accounts", "courses", "course_tags", "course_outlines", "items",
                              "sync_cursors", "assignments", "grade_items", "quizzes", "quiz_attempts",
                              "pending_deletions", "system_metadata"]
                for table in tables.reversed() { try executeUnsafe("DELETE FROM main.\(table)") }
                for table in tables { try executeUnsafe("INSERT INTO main.\(table) SELECT * FROM recovery.\(table)") }
                if resetRemoteContent {
                    // Domain-owned downloaded bytes may disappear during reset.
                    // User-owned paths already point at the durable personal store.
                    try executeUnsafe("UPDATE items SET local_path = NULL, sync_state = 'placeholder' WHERE is_local = 0 AND is_directory = 0")
                }
                try verifyRecoveryStateUnsafe()
            }
        }
    }

    private func verifyRecoveryStateUnsafe(schema: String = "main", requireComplete: Bool = true) throws {
        guard try scalarUnsafe("PRAGMA \(schema).user_version") == Self.schemaVersion else {
            throw FindleError.databaseError(detail: "The database snapshot uses an unsupported schema")
        }
        if requireComplete, try scalarUnsafe("SELECT value FROM \(schema).system_metadata WHERE key = 'seed_complete'") != 1 {
            throw FindleError.databaseError(detail: "The database snapshot is incomplete")
        }
        let integrity = try prepareStatement("PRAGMA \(schema).quick_check")
        defer { sqlite3_finalize(integrity) }
        guard sqlite3_step(integrity) == SQLITE_ROW,
              sqlite3_column_text(integrity, 0).map({ String(cString: $0) }) == "ok" else {
            throw FindleError.databaseError(detail: "The database snapshot did not pass its integrity check")
        }
        let counter = try scalarUnsafe("SELECT value FROM \(schema).system_metadata WHERE key = 'change_counter'")
        let itemCounter = try scalarUnsafe("SELECT COALESCE(MAX(updated_at), 0) FROM \(schema).items")
        let deletionCounter = try scalarUnsafe("SELECT COALESCE(MAX(deleted_at_counter), 0) FROM \(schema).pending_deletions")
        guard counter >= max(itemCounter, deletionCounter) else {
            throw FindleError.databaseError(detail: "The database snapshot has an incomplete change counter")
        }
    }

    private static func synchronizeRecoveryFile(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

// MARK: - Course Snapshot Publication

extension Database {
    /// Publish an accepted, complete remote course snapshot as one revision.
    /// Readers on other connections see either the old revision or the committed
    /// one, including its tombstones, change counters, cursor, and outline.
    /// Callers check cancellation before entering; this synchronous operation has
    /// no cancellation boundary that could expose only part of a course update.
    public func commitCourseSync(
        items: [LocalItem],
        deletingItemIDs: [String],
        cursor: SyncCursor,
        outline: CourseOutlineSnapshot
    ) throws {
        guard outline.courseID == cursor.courseID,
              items.allSatisfy({ $0.courseID == cursor.courseID && $0.siteID == cursor.siteID }) else {
            throw FindleError.databaseError(detail: "Course snapshot contains mismatched course or site identifiers")
        }
        let payload = try JSONEncoder().encode(outline)
        try queue.sync {
            try transactionUnsafe {
                try saveItemsUnsafe(items)
                try deleteItemsWithTombstoneUnsafe(ids: deletingItemIDs)
                try saveSyncCursorUnsafe(cursor)
                try saveCourseOutlineUnsafe(courseID: outline.courseID, siteID: cursor.siteID, payload: payload)
            }
        }
    }

    /// The caller must hold `queue`. The body must use queue-held helpers only.
    private func transactionUnsafe(_ body: () throws -> Void) throws {
        try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
        do {
            try body()
            try executeUnsafe("COMMIT")
        } catch {
            try? executeUnsafe("ROLLBACK")
            throw error
        }
    }
}

// MARK: - Course Outline Operations

extension Database {
    public func saveCourseOutline(_ outline: CourseOutlineSnapshot, siteID: String) throws {
        let payload = try JSONEncoder().encode(outline)
        try queue.sync {
            try saveCourseOutlineUnsafe(courseID: outline.courseID, siteID: siteID, payload: payload)
        }
    }

    private func saveCourseOutlineUnsafe(courseID: Int, siteID: String, payload: Data) throws {
        let stmt = try prepareStatement("INSERT OR REPLACE INTO course_outlines (course_id, site_id, payload, updated_at) VALUES (?, ?, ?, ?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(courseID))
        sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
        _ = payload.withUnsafeBytes { bytes in
            sqlite3_bind_text(stmt, 3, bytes.bindMemory(to: CChar.self).baseAddress, Int32(payload.count), SQLITE_TRANSIENT)
        }
        sqlite3_bind_double(stmt, 4, Date().timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw FindleError.databaseError(detail: "Failed to save course outline")
        }
    }

    public func fetchCourseOutline(courseID: Int, siteID: String) throws -> CourseOutlineSnapshot? {
        try queue.sync {
            let stmt = try prepareStatement("SELECT payload FROM course_outlines WHERE course_id = ? AND site_id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(courseID))
            sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let payload = sqlite3_column_text(stmt, 0) else { return nil }
            return try JSONDecoder().decode(
                CourseOutlineSnapshot.self,
                from: Data(bytes: payload, count: Int(sqlite3_column_bytes(stmt, 0)))
            )
        }
    }

    public func fetchCourseOutlines(siteID: String) throws -> [CourseOutlineSnapshot] {
        try queue.sync {
            let stmt = try prepareStatement("SELECT payload FROM course_outlines WHERE site_id = ? ORDER BY course_id")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            var outlines: [CourseOutlineSnapshot] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let payload = sqlite3_column_text(stmt, 0) else { continue }
                let data = Data(bytes: payload, count: Int(sqlite3_column_bytes(stmt, 0)))
                outlines.append(try JSONDecoder().decode(CourseOutlineSnapshot.self, from: data))
            }
            return outlines
        }
    }

    public func deleteCourseOutline(courseID: Int, siteID: String) throws {
        try queue.sync {
            let stmt = try prepareStatement("DELETE FROM course_outlines WHERE course_id = ? AND site_id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(courseID))
            sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to delete course outline")
            }
        }
    }
}

// MARK: - Course Tag Operations

extension Database {
    public func saveCourseTags(_ tags: [FinderTag], courseID: Int, siteID: String) throws {
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                let deleteSQL = "DELETE FROM course_tags WHERE course_id = ? AND site_id = ?"
                let deleteStmt = try prepareStatement(deleteSQL)
                defer { sqlite3_finalize(deleteStmt) }
                sqlite3_bind_int64(deleteStmt, 1, Int64(courseID))
                sqlite3_bind_text(deleteStmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                    throw FindleError.databaseError(detail: "saveCourseTags delete failed: \(String(cString: sqlite3_errmsg(db)))")
                }

                let insertSQL = "INSERT INTO course_tags (course_id, site_id, tag_name, tag_color) VALUES (?, ?, ?, ?)"
                for tag in tags {
                    let stmt = try prepareStatement(insertSQL)
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_int64(stmt, 1, Int64(courseID))
                    sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 3, (tag.name as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int(stmt, 4, Int32(tag.color.rawValue))
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw FindleError.databaseError(detail: "saveCourseTags insert failed: \(String(cString: sqlite3_errmsg(db)))")
                    }
                }

                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    public func fetchCourseTags(courseID: Int, siteID: String) throws -> [FinderTag] {
        let sql = "SELECT tag_name, tag_color FROM course_tags WHERE course_id = ? AND site_id = ? ORDER BY tag_name"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(courseID))
            sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)

            var tags: [FinderTag] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let colorRaw = Int(sqlite3_column_int(stmt, 1))
                let color = FinderTag.Color(rawValue: colorRaw) ?? .none
                tags.append(FinderTag(name: name, color: color))
            }
            return tags
        }
    }

    public func fetchAllCourseTags(siteID: String) throws -> [Int: [FinderTag]] {
        let sql = "SELECT course_id, tag_name, tag_color FROM course_tags WHERE site_id = ? ORDER BY course_id, tag_name"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)

            var result: [Int: [FinderTag]] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                let courseID = Int(sqlite3_column_int64(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let colorRaw = Int(sqlite3_column_int(stmt, 2))
                let color = FinderTag.Color(rawValue: colorRaw) ?? .none
                result[courseID, default: []].append(FinderTag(name: name, color: color))
            }
            return result
        }
    }
}

// MARK: - Item Operations

extension Database {
    public func saveItems(_ items: [LocalItem]) throws {
        try queue.sync {
            try transactionUnsafe { try saveItemsUnsafe(items) }
        }
    }

    /// A personal-store observation paired with the row it was derived from.
    /// `nil` expects that no writer has created the ID yet.
    struct LocalItemUpdate {
        let item: LocalItem
        let expected: LocalItem?
    }

    /// Apply only observations whose source rows still match, after taking the
    /// write lock. Finder changes made during a filesystem scan take precedence.
    @discardableResult
    func saveLocalItemsIfUnchanged(_ updates: [LocalItemUpdate]) throws -> Int {
        guard !updates.isEmpty else { return 0 }
        return try queue.sync {
            var saved = 0
            try transactionUnsafe {
                for update in updates {
                    guard update.item.isLocal,
                          update.expected == nil || update.expected?.id == update.item.id else {
                        throw FindleError.databaseError(detail: "Invalid personal-file update")
                    }
                    guard try fetchItemUnsafe(id: update.item.id) == update.expected else { continue }
                    try saveItemsUnsafe([update.item])
                    saved += 1
                }
            }
            return saved
        }
    }

    /// The caller holds `queue`; unlike public readers this must not re-enter it.
    private func fetchItemUnsafe(id: String) throws -> LocalItem? {
        let statement = try prepareStatement("SELECT * FROM items WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return readItem(from: statement)
        case SQLITE_DONE: return nil
        default: throw FindleError.databaseError(detail: "Failed to read personal item: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Called only while holding the database queue and an open write transaction.
    private func saveItemsUnsafe(_ items: [LocalItem]) throws {
        let sql = """
            INSERT OR REPLACE INTO items (id, parent_id, site_id, course_id, remote_id,
                filename, is_directory, content_type, file_size, creation_date,
                modification_date, sync_state, is_pinned, local_path, remote_url, content_version, tag_data, is_local)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        let clearTombstoneStmt = try prepareStatement("DELETE FROM pending_deletions WHERE item_id = ?")
        defer { sqlite3_finalize(clearTombstoneStmt) }

        for item in items {
            // A reintroduced remote item must not retain the tombstone
            // from its previous deletion. Otherwise a later change
            // enumeration can delete the newly-created Finder item.
            sqlite3_reset(clearTombstoneStmt)
            sqlite3_bind_text(clearTombstoneStmt, 1, (item.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(clearTombstoneStmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "saveItems tombstone cleanup failed")
            }

            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (item.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let p = item.parentID { sqlite3_bind_text(stmt, 2, (p as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_text(stmt, 3, (item.siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 4, Int64(item.courseID))
            sqlite3_bind_int64(stmt, 5, Int64(item.remoteID))
            sqlite3_bind_text(stmt, 6, (item.filename as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 7, item.isDirectory ? 1 : 0)
            if let ct = item.contentType { sqlite3_bind_text(stmt, 8, (ct as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            sqlite3_bind_int64(stmt, 9, item.fileSize)
            if let d = item.creationDate { sqlite3_bind_double(stmt, 10, d.timeIntervalSince1970) }
            if let d = item.modificationDate { sqlite3_bind_double(stmt, 11, d.timeIntervalSince1970) }
            sqlite3_bind_text(stmt, 12, (item.syncState.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 13, item.isPinned ? 1 : 0)
            if let lp = item.localPath { sqlite3_bind_text(stmt, 14, (lp as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            if let ru = item.remoteURL { sqlite3_bind_text(stmt, 15, (ru.absoluteString as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            if let cv = item.contentVersion { sqlite3_bind_text(stmt, 16, (cv as NSString).utf8String, -1, SQLITE_TRANSIENT) }
            if let td = item.tagData {
                sqlite3_bind_blob(stmt, 17, (td as NSData).bytes, Int32(td.count), SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 17)
            }
            sqlite3_bind_int(stmt, 18, item.isLocal ? 1 : 0)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "saveItems step failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    public func fetchItems(parentID: String?) throws -> [LocalItem] {
        return try queue.sync {
            let stmt: OpaquePointer
            if let parentID = parentID {
                stmt = try prepareStatement("SELECT * FROM items WHERE parent_id = ? ORDER BY is_directory DESC, filename")
                sqlite3_bind_text(stmt, 1, (parentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                stmt = try prepareStatement("SELECT * FROM items WHERE parent_id IS NULL ORDER BY is_directory DESC, filename")
            }
            defer { sqlite3_finalize(stmt) }
            return try readItems(from: stmt)
        }
    }

    /// Return children in a single File Provider domain. Root enumeration must
    /// be scoped as well as working-set enumeration; otherwise stale data from
    /// another Moodle site can leak into this domain's Finder root.
    public func fetchItems(parentID: String?, siteID: String) throws -> [LocalItem] {
        try queue.sync {
            let stmt: OpaquePointer
            if let parentID {
                stmt = try prepareStatement("SELECT * FROM items WHERE parent_id = ? AND site_id = ? ORDER BY is_directory DESC, filename")
                sqlite3_bind_text(stmt, 1, (parentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                stmt = try prepareStatement("SELECT * FROM items WHERE parent_id IS NULL AND site_id = ? ORDER BY is_directory DESC, filename")
                sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
            defer { sqlite3_finalize(stmt) }
            return try readItems(from: stmt)
        }
    }

    public func fetchItem(id: String) throws -> LocalItem? {
        let sql = "SELECT * FROM items WHERE id = ?"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)

            switch sqlite3_step(stmt) {
            case SQLITE_ROW: return readItem(from: stmt)
            case SQLITE_DONE: return nil
            default: throw FindleError.databaseError(detail: "Failed to read item")
            }
        }
    }

    public func fetchAllItems(siteID: String) throws -> [LocalItem] {
        let sql = "SELECT * FROM items WHERE site_id = ? ORDER BY is_directory DESC, filename"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            return try readItems(from: stmt)
        }
    }

    /// Every user-owned row for a site: `local-` files and folders, plus the
    /// stand-in directories that keep their content visible after unsync.
    public func fetchLocalItems(siteID: String) throws -> [LocalItem] {
        let sql = "SELECT * FROM items WHERE site_id = ? AND is_local = 1 ORDER BY is_directory DESC, filename"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            return try readItems(from: stmt)
        }
    }

    public func fetchItems(courseID: Int, siteID: String) throws -> [LocalItem] {
        let sql = "SELECT * FROM items WHERE course_id = ? AND site_id = ? ORDER BY is_directory DESC, filename"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(courseID))
            sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            return try readItems(from: stmt)
        }
    }

    public func updateItemFilename(id: String, filename: String) throws {
        let sql = "UPDATE items SET filename = ?, modification_date = ? WHERE id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (filename as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to update item filename")
            }
        }
    }

    public func updateItemTagData(id: String, tagData: Data?) throws {
        let sql = "UPDATE items SET tag_data = ?, modification_date = ? WHERE id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            if let td = tagData {
                sqlite3_bind_blob(stmt, 1, (td as NSData).bytes, Int32(td.count), SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to update item tag data")
            }
        }
    }

    public func updateItemSyncState(id: String, state: ItemSyncState, localPath: String? = nil) throws {
        let sql: String
        if localPath != nil {
            sql = "UPDATE items SET sync_state = ?, local_path = ? WHERE id = ?"
        } else {
            sql = "UPDATE items SET sync_state = ? WHERE id = ?"
        }
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (state.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let path = localPath {
                sqlite3_bind_text(stmt, 2, (path as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to update item sync state")
            }
        }
    }

    /// Publish a download only while its source row still matches. A sync
    /// replacing/deleting that row must win over stale completion callbacks.
    public func updateDownloadState(
        for item: LocalItem, state: ItemSyncState, localPath: String? = nil,
        onlyIfDownloading: Bool = false
    ) throws -> LocalItem? {
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE")
            do {
                let pathClause = localPath == nil ? "" : ", local_path = ?"
                let stateClause = onlyIfDownloading ? " AND sync_state = 'downloading'" : ""
                let sql = """
                    UPDATE items SET sync_state = ?\(pathClause)
                    WHERE id = ? AND site_id = ? AND content_version IS ?
                    AND remote_url IS ? AND is_local = ? AND file_size = ?\(stateClause)
                    """
                let stmt = try prepareStatement(sql)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (state.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
                var index: Int32 = 2
                if let localPath {
                    sqlite3_bind_text(stmt, index, (localPath as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    index += 1
                }
                sqlite3_bind_text(stmt, index, (item.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, index + 1, (item.siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if let version = item.contentVersion {
                    sqlite3_bind_text(stmt, index + 2, (version as NSString).utf8String, -1, SQLITE_TRANSIENT)
                } else { sqlite3_bind_null(stmt, index + 2) }
                if let url = item.remoteURL?.absoluteString {
                    sqlite3_bind_text(stmt, index + 3, (url as NSString).utf8String, -1, SQLITE_TRANSIENT)
                } else { sqlite3_bind_null(stmt, index + 3) }
                sqlite3_bind_int(stmt, index + 4, item.isLocal ? 1 : 0)
                sqlite3_bind_int64(stmt, index + 5, item.fileSize)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw FindleError.databaseError(detail: "Failed to update download state")
                }
                var updated: LocalItem?
                if sqlite3_changes(db) > 0 {
                    let read = try prepareStatement("SELECT * FROM items WHERE id = ?")
                    defer { sqlite3_finalize(read) }
                    sqlite3_bind_text(read, 1, (item.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    guard sqlite3_step(read) == SQLITE_ROW else {
                        throw FindleError.databaseError(detail: "Failed to read published download")
                    }
                    updated = readItem(from: read)
                }
                try executeUnsafe("COMMIT")
                return updated
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    /// Reset items stuck in the transient `.downloading` state back to
    /// `.placeholder`. A download can't survive the process that started it, so
    /// any `.downloading` row found at launch is stale and would otherwise show
    /// a perpetual in-progress state. Returns the number of rows reset.
    @discardableResult
    public func resetStaleDownloads(siteID: String) throws -> Int {
        try queue.sync {
            let stmt = try prepareStatement(
                "UPDATE items SET sync_state = ? WHERE site_id = ? AND sync_state = ?"
            )
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (ItemSyncState.placeholder.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, (ItemSyncState.downloading.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to reset stale downloads")
            }
            return Int(sqlite3_changes(db))
        }
    }

    public func updateItemPinned(id: String, isPinned: Bool) throws {
        let sql = "UPDATE items SET is_pinned = ? WHERE id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, isPinned ? 1 : 0)
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to update item pinned state")
            }
        }
    }

    public func pinItemsRecursively(id: String, isPinned: Bool) throws {
        try updateItemPinned(id: id, isPinned: isPinned)
        let children = try fetchItems(parentID: id)
        for child in children {
            try pinItemsRecursively(id: child.id, isPinned: isPinned)
        }
    }

    public func fetchPinnedItems(siteID: String) throws -> [LocalItem] {
        let sql = "SELECT * FROM items WHERE site_id = ? AND is_pinned = 1 AND is_directory = 0 ORDER BY filename"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            return try readItems(from: stmt)
        }
    }

    public func deleteItems(courseID: Int, siteID: String) throws {
        let ids = try fetchItems(courseID: courseID, siteID: siteID)
            .filter { !$0.isLocal }
            .map(\.id)
        try deleteItemsWithTombstone(ids: ids)
    }

    public func deleteAllItems(siteID: String) throws {
        let ids = try fetchAllItems(siteID: siteID)
            .filter { !$0.isLocal }
            .map(\.id)
        try deleteItemsWithTombstone(ids: ids)
    }

    /// Delete the given remote items (and their remote descendants) and record
    /// a tombstone in `pending_deletions` so the File Provider extension can
    /// report the deletion to Finder on the next change enumeration. All work
    /// happens in a single transaction so partial failures don't leak rows.
    ///
    /// User-owned items (`is_local = 1`) are never deleted or moved. A directory
    /// that contains any local item at any depth survives, and so does every
    /// ancestor on the path to that item. Its remote siblings without local
    /// content are still deleted.
    public func deleteItemsWithTombstone(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try transactionUnsafe { try deleteItemsWithTombstoneUnsafe(ids: ids) }
        }
    }

    /// Called only while holding the database queue and an open write transaction.
    private func deleteItemsWithTombstoneUnsafe(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        var idsToDelete = Set<String>()
        var frontier: [String] = []
        var parentByID: [String: String] = [:]
        var siteByID: [String: String] = [:]
        var siteIDs = Set<String>()

        let initialStmt = try prepareStatement("SELECT id, is_local, site_id FROM items WHERE id = ?")
        defer { sqlite3_finalize(initialStmt) }
        for id in ids {
            sqlite3_reset(initialStmt)
            sqlite3_bind_text(initialStmt, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(initialStmt) == SQLITE_ROW else { continue }
            guard sqlite3_column_int(initialStmt, 1) == 0 else { continue }
            let siteID = String(cString: sqlite3_column_text(initialStmt, 2))
            siteByID[id] = siteID
            siteIDs.insert(siteID)
            if idsToDelete.insert(id).inserted {
                frontier.append(id)
            }
        }

        // Only load the hierarchy of the sites being touched. Loading
        // every item in the database made each deletion O(total items).
        let hierarchyStmt = try prepareStatement("SELECT id, parent_id, site_id, is_local FROM items WHERE site_id = ?")
        defer { sqlite3_finalize(hierarchyStmt) }
        var localIDs: [String] = []
        for siteID in siteIDs {
            sqlite3_reset(hierarchyStmt)
            sqlite3_bind_text(hierarchyStmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            while sqlite3_step(hierarchyStmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(hierarchyStmt, 0))
                parentByID[id] = sqlite3_column_text(hierarchyStmt, 1).map { String(cString: $0) } ?? ""
                siteByID[id] = String(cString: sqlite3_column_text(hierarchyStmt, 2))
                if sqlite3_column_int(hierarchyStmt, 3) == 1 {
                    localIDs.append(id)
                }
            }
        }

        // Pin every local item and its ancestors. Walking up stops at the
        // first ancestor that is already pinned, so shared paths are visited once.
        var pinnedIDs = Set<String>()
        for localID in localIDs {
            var current: String? = localID
            while let id = current, pinnedIDs.insert(id).inserted {
                current = parentByID[id].flatMap { $0.isEmpty ? nil : $0 }
            }
        }

        let childStmt = try prepareStatement("SELECT id, is_local, site_id FROM items WHERE parent_id = ?")
        defer { sqlite3_finalize(childStmt) }

        while !frontier.isEmpty {
            var nextFrontier: [String] = []
            for parentID in frontier {
                sqlite3_reset(childStmt)
                sqlite3_bind_text(childStmt, 1, (parentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                while sqlite3_step(childStmt) == SQLITE_ROW {
                    let childID = String(cString: sqlite3_column_text(childStmt, 0))
                    let childIsLocal = sqlite3_column_int(childStmt, 1) == 1
                    siteByID[childID] = String(cString: sqlite3_column_text(childStmt, 2))
                    // Local children are kept in place. Their ancestors are pinned above.
                    guard !childIsLocal else { continue }
                    if idsToDelete.insert(childID).inserted {
                        nextFrontier.append(childID)
                    }
                }
            }
            frontier = nextFrontier
        }

        let tombstoneStmt = try prepareStatement("INSERT OR IGNORE INTO pending_deletions (item_id, site_id) VALUES (?, ?)")
        defer { sqlite3_finalize(tombstoneStmt) }
        let deleteStmt = try prepareStatement("DELETE FROM items WHERE id = ?")
        defer { sqlite3_finalize(deleteStmt) }

        // A pinned remote directory is a container for user work, so it is
        // skipped here even though it was requested for deletion.
        for itemID in idsToDelete.subtracting(pinnedIDs) {
            sqlite3_reset(tombstoneStmt)
            sqlite3_bind_text(tombstoneStmt, 1, (itemID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(tombstoneStmt, 2, ((siteByID[itemID] ?? "") as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(tombstoneStmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "deleteItemsWithTombstone tombstone failed")
            }
            sqlite3_reset(deleteStmt)
            sqlite3_bind_text(deleteStmt, 1, (itemID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "deleteItemsWithTombstone delete failed")
            }
        }
    }

    /// Delete a single item and all its children by ID. Used when the user
    /// deletes a file or folder from Finder, so every removed row gets a
    /// tombstone in `pending_deletions`. That lets change enumeration report
    /// the deletion, and the tombstone write also bumps the change counter.
    ///
    /// - Returns: the `local_path` of every deleted row that has one, so the
    ///   caller can remove the matching content files from disk.
    @discardableResult
    public func deleteItemAndChildren(id: String) throws -> [String] {
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                let deleted = try deleteSubtreeWithTombstones(rootID: id)
                try executeUnsafe("COMMIT")
                return deleted.compactMap(\.localPath)
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    /// Delete confirmed stale personal rows only if they are unchanged leaves
    /// under the write lock. A newly arrived/changed child keeps every ancestor;
    /// this method never recursively deletes descendants of a stale candidate.
    @discardableResult
    func deleteLocalItemsIfUnchanged(_ expectedItems: [LocalItem]) throws -> Int {
        guard !expectedItems.isEmpty else { return 0 }
        return try queue.sync {
            var deleted = 0
            try transactionUnsafe {
                let childStatement = try prepareStatement("SELECT 1 FROM items WHERE parent_id = ? LIMIT 1")
                defer { sqlite3_finalize(childStatement) }
                let tombstoneStatement = try prepareStatement("INSERT OR IGNORE INTO pending_deletions (item_id, site_id) VALUES (?, ?)")
                defer { sqlite3_finalize(tombstoneStatement) }
                let deleteStatement = try prepareStatement("DELETE FROM items WHERE id = ?")
                defer { sqlite3_finalize(deleteStatement) }
                var remaining = expectedItems.filter { $0.isLocal && $0.id.hasPrefix("local-") }
                while !remaining.isEmpty {
                    var parents: [LocalItem] = []
                    let previousCount = deleted
                    for expected in remaining {
                        guard try fetchItemUnsafe(id: expected.id) == expected else { continue }
                        sqlite3_reset(childStatement)
                        sqlite3_bind_text(childStatement, 1, (expected.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                        let childStatus = sqlite3_step(childStatement)
                        if childStatus == SQLITE_ROW {
                            parents.append(expected)
                            continue
                        }
                        guard childStatus == SQLITE_DONE else {
                            throw FindleError.databaseError(detail: "Failed to check personal item children")
                        }
                        sqlite3_reset(tombstoneStatement)
                        sqlite3_bind_text(tombstoneStatement, 1, (expected.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                        sqlite3_bind_text(tombstoneStatement, 2, (expected.siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                        guard sqlite3_step(tombstoneStatement) == SQLITE_DONE else {
                            throw FindleError.databaseError(detail: "Failed to record stale personal item deletion")
                        }
                        sqlite3_reset(deleteStatement)
                        sqlite3_bind_text(deleteStatement, 1, (expected.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                        guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
                            throw FindleError.databaseError(detail: "Failed to delete stale personal item")
                        }
                        deleted += 1
                    }
                    guard deleted > previousCount else { break }
                    remaining = parents
                }
            }
            return deleted
        }
    }

    /// Delete each of the given items and their descendants in one transaction,
    /// with a tombstone for every removed row. IDs that don't exist are ignored.
    public func deleteLocalItems(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                for id in ids {
                    _ = try deleteSubtreeWithTombstones(rootID: id)
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    /// Delete the directories in `courseIDs` that hold no user-created content.
    /// A directory is kept when any `local-` item sits beneath it, and kept
    /// directories are never deleted. Stand-in directories and remote
    /// directories without local content are removed bottom-up along with
    /// their remote descendants, and each removed row gets a tombstone.
    ///
    /// - Returns: the number of rows deleted, including remote descendants
    ///   removed with a pruned directory.
    @discardableResult
    public func pruneDirectoriesWithoutLocalContent(courseIDs: [Int], siteID: String) throws -> Int {
        guard !courseIDs.isEmpty else { return 0 }
        return try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                var parentByID: [String: String] = [:]
                var directoryIDs = Set<String>()
                var localIDs: [String] = []

                let courseStmt = try prepareStatement("SELECT id, parent_id, is_directory, is_local FROM items WHERE course_id = ? AND site_id = ?")
                defer { sqlite3_finalize(courseStmt) }
                for courseID in courseIDs {
                    sqlite3_reset(courseStmt)
                    sqlite3_bind_int64(courseStmt, 1, Int64(courseID))
                    sqlite3_bind_text(courseStmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    while sqlite3_step(courseStmt) == SQLITE_ROW {
                        let id = String(cString: sqlite3_column_text(courseStmt, 0))
                        parentByID[id] = sqlite3_column_text(courseStmt, 1).map { String(cString: $0) } ?? ""
                        if sqlite3_column_int(courseStmt, 2) == 1 {
                            directoryIDs.insert(id)
                        }
                        if sqlite3_column_int(courseStmt, 3) == 1, id.hasPrefix("local-") {
                            localIDs.append(id)
                        }
                    }
                }

                // Keep every ancestor of user-created content, stopping at the first kept one.
                var keptIDs = Set<String>()
                for localID in localIDs {
                    var current: String? = localID
                    while let id = current, keptIDs.insert(id).inserted {
                        current = parentByID[id].flatMap { $0.isEmpty ? nil : $0 }
                    }
                }

                // Depth decides the order: deepest first, so a course root is removed
                // only after its sections have been pruned.
                func depth(of id: String) -> Int {
                    var count = 0
                    var current = parentByID[id].flatMap { $0.isEmpty ? nil : $0 }
                    var visited: Set<String> = [id]
                    while let parent = current, visited.insert(parent).inserted {
                        count += 1
                        current = parentByID[parent].flatMap { $0.isEmpty ? nil : $0 }
                    }
                    return count
                }
                let candidates = directoryIDs
                    .subtracting(keptIDs)
                    .filter { !$0.hasPrefix("local-") }
                    .sorted { depth(of: $0) > depth(of: $1) }

                var deletedCount = 0
                for candidate in candidates {
                    // Rows already removed with an earlier, deeper candidate are not found again.
                    deletedCount += try deleteSubtreeWithTombstones(rootID: candidate).count
                }
                try executeUnsafe("COMMIT")
                return deletedCount
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    /// Rewrite `local_path` for user-created items under a moved or renamed
    /// folder. Only rows whose path equals `oldPrefix` or starts with
    /// `oldPrefix + "/"` change, so `/a/b` does not match `/a/bc`. The
    /// `items_bump_after_update` trigger covers `local_path`, so the change
    /// counter advances for each row.
    ///
    /// - Returns: the number of rows changed.
    @discardableResult
    public func updateLocalPaths(fromPrefix oldPrefix: String, toPrefix newPrefix: String, siteID: String) throws -> Int {
        guard oldPrefix != newPrefix else { return 0 }
        let sql = """
            UPDATE items
            SET local_path = ?1 || substr(local_path, length(?2) + 1)
            WHERE site_id = ?3 AND is_local = 1
              AND (local_path = ?4 OR substr(local_path, 1, length(?5) + 1) = ?6 || '/')
        """
        return try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                let stmt = try prepareStatement(sql)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (newPrefix as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, (oldPrefix as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 3, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, (oldPrefix as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, (oldPrefix as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 6, (oldPrefix as NSString).utf8String, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw FindleError.databaseError(detail: "updateLocalPaths failed: \(String(cString: sqlite3_errmsg(db)))")
                }
                let changed = Int(sqlite3_changes(db))
                try executeUnsafe("COMMIT")
                return changed
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    /// Delete `rootID` and all of its descendants, record a tombstone for each
    /// removed row, and return the removed rows. The caller must already hold
    /// an open transaction on `queue`.
    private func deleteSubtreeWithTombstones(rootID id: String) throws -> [(id: String, siteID: String, localPath: String?)] {
        // Delete children first (recursive via parent_id chain).
        // Collect every descendant with its site and local path, then delete them.
        var deleted: [(id: String, siteID: String, localPath: String?)] = []
        var visited = Set<String>()
        var frontier = [id]

        let rootStmt = try prepareStatement("SELECT id, site_id, local_path FROM items WHERE id = ?")
        defer { sqlite3_finalize(rootStmt) }
        sqlite3_bind_text(rootStmt, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if sqlite3_step(rootStmt) == SQLITE_ROW {
            deleted.append(readDeletionTarget(from: rootStmt))
            visited.insert(id)
        }

        let childStmt = try prepareStatement("SELECT id, site_id, local_path FROM items WHERE parent_id = ?")
        defer { sqlite3_finalize(childStmt) }
        while !frontier.isEmpty {
            var nextFrontier: [String] = []
            for parentID in frontier {
                sqlite3_reset(childStmt)
                sqlite3_bind_text(childStmt, 1, (parentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                while sqlite3_step(childStmt) == SQLITE_ROW {
                    let child = readDeletionTarget(from: childStmt)
                    guard visited.insert(child.id).inserted else { continue }
                    deleted.append(child)
                    nextFrontier.append(child.id)
                }
            }
            frontier = nextFrontier
        }

        let tombstoneStmt = try prepareStatement("INSERT OR IGNORE INTO pending_deletions (item_id, site_id) VALUES (?, ?)")
        defer { sqlite3_finalize(tombstoneStmt) }
        let deleteStmt = try prepareStatement("DELETE FROM items WHERE id = ?")
        defer { sqlite3_finalize(deleteStmt) }

        for item in deleted {
            sqlite3_reset(tombstoneStmt)
            sqlite3_bind_text(tombstoneStmt, 1, (item.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(tombstoneStmt, 2, (item.siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(tombstoneStmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "deleteSubtreeWithTombstones tombstone failed: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_reset(deleteStmt)
            sqlite3_bind_text(deleteStmt, 1, (item.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "deleteSubtreeWithTombstones delete failed: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        return deleted
    }

    /// Read `(id, site_id, local_path)` from a statement positioned on a row.
    /// Only call from within a `queue.sync` block.
    private func readDeletionTarget(from stmt: OpaquePointer) -> (id: String, siteID: String, localPath: String?) {
        (
            id: String(cString: sqlite3_column_text(stmt, 0)),
            siteID: String(cString: sqlite3_column_text(stmt, 1)),
            localPath: sqlite3_column_text(stmt, 2).map { String(cString: $0) }
        )
    }

    public func fetchPendingDeletions() throws -> [String] {
        let sql = "SELECT item_id FROM pending_deletions ORDER BY deleted_at"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return ids
        }
    }

    public func fetchPendingDeletions(siteID: String) throws -> [String] {
        let sql = "SELECT item_id FROM pending_deletions WHERE site_id = ? ORDER BY deleted_at"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return ids
        }
    }

    /// Return the global monotonic change counter. The value is bumped by SQL
    /// triggers on writes to `items` and `pending_deletions`, so it's safe to
    /// use as a sync anchor handed to NSFileProviderChangeObserver.
    public func currentChangeCounter() throws -> Int64 {
        try queue.sync {
            let stmt = try prepareStatement("SELECT value FROM system_metadata WHERE key = 'change_counter'")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  sqlite3_column_type(stmt, 0) == SQLITE_INTEGER,
                  sqlite3_column_int64(stmt, 0) >= 0 else {
                throw FindleError.databaseError(detail: "Missing or unreadable change counter")
            }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    /// Keep a replicated database's change counter at or above a previous
    /// domain anchor before restoring rows. Subsequent item/tombstone triggers
    /// then stamp restored rows with counters newer than Finder's anchor.
    public func preserveChangeCounter(atLeast counter: Int64) throws {
        try queue.sync {
            let stmt = try prepareStatement("UPDATE system_metadata SET value = MAX(value, ?) WHERE key = 'change_counter'")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, counter)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to preserve change counter")
            }
        }
    }

    /// Return items in a container whose `updated_at` is strictly greater than `anchor`.
    /// Pass `parentID == nil` for root items, or a parent ID for a single container.
    public func fetchItemsChangedSince(anchor: Int64, parentID: String?) throws -> [LocalItem] {
        try fetchItemsChangedSince(anchor: anchor, parentID: parentID, through: nil)
    }

    /// Return changes in a container up to a captured counter. Bounding the
    /// query and the returned anchor prevents writes that happen during
    /// enumeration from being skipped permanently.
    public func fetchItemsChangedSince(anchor: Int64, parentID: String?, through upperBound: Int64?) throws -> [LocalItem] {
        let sql: String
        if parentID == nil {
            sql = upperBound == nil
                ? "SELECT * FROM items WHERE parent_id IS NULL AND updated_at > ? ORDER BY updated_at"
                : "SELECT * FROM items WHERE parent_id IS NULL AND updated_at > ? AND updated_at <= ? ORDER BY updated_at"
        } else {
            sql = upperBound == nil
                ? "SELECT * FROM items WHERE parent_id = ? AND updated_at > ? ORDER BY updated_at"
                : "SELECT * FROM items WHERE parent_id = ? AND updated_at > ? AND updated_at <= ? ORDER BY updated_at"
        }
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            var index: Int32 = 1
            if let parentID {
                sqlite3_bind_text(stmt, index, (parentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                index += 1
            }
            sqlite3_bind_int64(stmt, index, anchor)
            index += 1
            if let upperBound {
                sqlite3_bind_int64(stmt, index, upperBound)
            }
            return try readItems(from: stmt)
        }
    }

    public func fetchItemsChangedSince(
        anchor: Int64,
        parentID: String?,
        siteID: String,
        through upperBound: Int64?
    ) throws -> [LocalItem] {
        let sql: String
        if parentID == nil {
            sql = upperBound == nil
                ? "SELECT * FROM items WHERE parent_id IS NULL AND site_id = ? AND updated_at > ? ORDER BY updated_at"
                : "SELECT * FROM items WHERE parent_id IS NULL AND site_id = ? AND updated_at > ? AND updated_at <= ? ORDER BY updated_at"
        } else {
            sql = upperBound == nil
                ? "SELECT * FROM items WHERE parent_id = ? AND site_id = ? AND updated_at > ? ORDER BY updated_at"
                : "SELECT * FROM items WHERE parent_id = ? AND site_id = ? AND updated_at > ? AND updated_at <= ? ORDER BY updated_at"
        }
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            var index: Int32 = 1
            if let parentID {
                sqlite3_bind_text(stmt, index, (parentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                index += 1
            }
            sqlite3_bind_text(stmt, index, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            index += 1
            sqlite3_bind_int64(stmt, index, anchor)
            index += 1
            if let upperBound {
                sqlite3_bind_int64(stmt, index, upperBound)
            }
            return try readItems(from: stmt)
        }
    }

    /// Return all items for a site whose `updated_at` is strictly greater than `anchor`.
    public func fetchItemsChangedSince(anchor: Int64, siteID: String) throws -> [LocalItem] {
        try fetchItemsChangedSince(anchor: anchor, siteID: siteID, through: nil)
    }

    public func fetchItemsChangedSince(anchor: Int64, siteID: String, through upperBound: Int64?) throws -> [LocalItem] {
        let sql = upperBound == nil
            ? "SELECT * FROM items WHERE site_id = ? AND updated_at > ? ORDER BY updated_at"
            : "SELECT * FROM items WHERE site_id = ? AND updated_at > ? AND updated_at <= ? ORDER BY updated_at"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, anchor)
            if let upperBound {
                sqlite3_bind_int64(stmt, 3, upperBound)
            }
            return try readItems(from: stmt)
        }
    }

    /// Pending-deletion IDs whose `deleted_at_counter` is strictly greater
    /// than `anchor`. Returned in counter order so the enumerator can derive
    /// the next anchor from the last entry.
    public func fetchPendingDeletionsSince(anchor: Int64) throws -> [String] {
        try fetchPendingDeletionsSince(anchor: anchor, through: nil)
    }

    public func fetchPendingDeletionsSince(anchor: Int64, through upperBound: Int64?) throws -> [String] {
        try fetchPendingDeletionsSince(anchor: anchor, filterSiteID: nil, through: upperBound)
    }

    public func fetchPendingDeletionsSince(anchor: Int64, siteID: String, through upperBound: Int64?) throws -> [String] {
        try fetchPendingDeletionsSince(anchor: anchor, filterSiteID: siteID, through: upperBound)
    }

    private func fetchPendingDeletionsSince(anchor: Int64, filterSiteID: String?, through upperBound: Int64?) throws -> [String] {
        let siteClause = filterSiteID == nil ? "" : " AND site_id = ?"
        let upperBoundClause = upperBound == nil ? "" : " AND deleted_at_counter <= ?"
        let sql = "SELECT item_id FROM pending_deletions WHERE deleted_at_counter > ?\(siteClause)\(upperBoundClause) ORDER BY deleted_at_counter"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, anchor)
            var index: Int32 = 2
            if let filterSiteID {
                sqlite3_bind_text(stmt, index, (filterSiteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                index += 1
            }
            if let upperBound {
                sqlite3_bind_int64(stmt, index, upperBound)
            }
            var ids: [String] = []
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
                status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw FindleError.databaseError(detail: "Failed to read pending deletions") }
            return ids
        }
    }

    public func clearPendingDeletions() throws {
        try execute("DELETE FROM pending_deletions")
    }

    /// Recreate pending tombstones during a domain seed. New counters are
    /// assigned by the destination database so its change anchor remains
    /// monotonic after replication.
    public func savePendingDeletions(_ itemIDs: [String], siteID: String? = nil) throws {
        guard !itemIDs.isEmpty else { return }
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                let stmt = try prepareStatement("INSERT OR IGNORE INTO pending_deletions (item_id, site_id) VALUES (?, ?)")
                defer { sqlite3_finalize(stmt) }
                for itemID in itemIDs {
                    sqlite3_reset(stmt)
                    sqlite3_bind_text(stmt, 1, (itemID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 2, ((siteID ?? "") as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw FindleError.databaseError(detail: "Failed to restore pending deletion")
                    }
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    /// Whether a replicated File Provider database contains a complete seed.
    /// The app writes this marker last, after all copied rows are present, so
    /// the extension never adopts a partially-seeded database.
    public func isSeedComplete() throws -> Bool {
        try queue.sync {
            let stmt = try prepareStatement("SELECT value FROM system_metadata WHERE key = 'seed_complete'")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
            return sqlite3_column_int(stmt, 0) == 1
        }
    }

    public func setSeedComplete(_ complete: Bool) throws {
        try queue.sync {
            let stmt = try prepareStatement("INSERT OR REPLACE INTO system_metadata (key, value) VALUES ('seed_complete', ?)")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, complete ? 1 : 0)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to update seed state")
            }
        }
    }

    private func readItems(from stmt: OpaquePointer) throws -> [LocalItem] {
        var items: [LocalItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(readItem(from: stmt))
        }
        return items
    }

    private func readItem(from stmt: OpaquePointer) -> LocalItem {
        let colCount = sqlite3_column_count(stmt)

        let tagData: Data? = {
            guard colCount > 16, sqlite3_column_type(stmt, 16) != SQLITE_NULL else { return nil }
            let bytes = sqlite3_column_blob(stmt, 16)
            let length = sqlite3_column_bytes(stmt, 16)
            guard let bytes, length > 0 else { return nil }
            return Data(bytes: bytes, count: Int(length))
        }()

        // `is_local` was added before `updated_at` in older databases but
        // after it in newly-created databases. Resolve it by name so the
        // decoded value stays correct across both column layouts.
        let isLocalIndex = columnIndex(stmt, named: "is_local")
        let isLocal = isLocalIndex.map { sqlite3_column_int(stmt, $0) == 1 } ?? false

        return LocalItem(
            id: String(cString: sqlite3_column_text(stmt, 0)),
            parentID: sqlite3_column_text(stmt, 1).map { String(cString: $0) },
            siteID: String(cString: sqlite3_column_text(stmt, 2)),
            courseID: Int(sqlite3_column_int64(stmt, 3)),
            remoteID: Int(sqlite3_column_int64(stmt, 4)),
            filename: String(cString: sqlite3_column_text(stmt, 5)),
            isDirectory: sqlite3_column_int(stmt, 6) == 1,
            contentType: sqlite3_column_text(stmt, 7).map { String(cString: $0) },
            fileSize: sqlite3_column_int64(stmt, 8),
            creationDate: sqlite3_column_type(stmt, 9) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)) : nil,
            modificationDate: sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10)) : nil,
            syncState: ItemSyncState(rawValue: String(cString: sqlite3_column_text(stmt, 11))) ?? .placeholder,
            isPinned: sqlite3_column_int(stmt, 12) == 1,
            localPath: sqlite3_column_text(stmt, 13).map { String(cString: $0) },
            remoteURL: sqlite3_column_text(stmt, 14).flatMap { URL(string: String(cString: $0)) },
            contentVersion: sqlite3_column_text(stmt, 15).map { String(cString: $0) },
            tagData: tagData,
            isLocal: isLocal
        )
    }

    private func columnIndex(_ stmt: OpaquePointer, named name: String) -> Int32? {
        let count = sqlite3_column_count(stmt)
        for index in 0..<count {
            guard let columnName = sqlite3_column_name(stmt, index) else { continue }
            if String(cString: columnName) == name {
                return index
            }
        }
        return nil
    }
}

// MARK: - Sync Cursor Operations

extension Database {
    public func saveSyncCursor(_ cursor: SyncCursor) throws {
        try queue.sync { try saveSyncCursorUnsafe(cursor) }
    }

    private func saveSyncCursorUnsafe(_ cursor: SyncCursor) throws {
        let sql = """
            INSERT OR REPLACE INTO sync_cursors (course_id, site_id, last_sync_date, last_modified, item_count)
            VALUES (?, ?, ?, ?, ?)
        """
        let stmt = try prepareStatement(sql)
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, Int64(cursor.courseID))
        sqlite3_bind_text(stmt, 2, (cursor.siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 3, cursor.lastSyncDate.timeIntervalSince1970)
        if let lm = cursor.lastModified { sqlite3_bind_double(stmt, 4, lm.timeIntervalSince1970) }
        sqlite3_bind_int64(stmt, 5, Int64(cursor.itemCount))

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw FindleError.databaseError(detail: "Failed to save sync cursor: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    public func fetchSyncCursor(courseID: Int, siteID: String) throws -> SyncCursor? {
        let sql = "SELECT * FROM sync_cursors WHERE course_id = ? AND site_id = ?"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(courseID))
            sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

            return SyncCursor(
                courseID: Int(sqlite3_column_int64(stmt, 0)),
                siteID: String(cString: sqlite3_column_text(stmt, 1)),
                lastSyncDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                lastModified: sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)) : nil,
                itemCount: Int(sqlite3_column_int64(stmt, 4))
            )
        }
    }

    public func fetchAllSyncCursors(siteID: String) throws -> [SyncCursor] {
        let sql = "SELECT * FROM sync_cursors WHERE site_id = ?"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)

            var cursors: [SyncCursor] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                cursors.append(
                    SyncCursor(
                        courseID: Int(sqlite3_column_int64(stmt, 0)),
                        siteID: String(cString: sqlite3_column_text(stmt, 1)),
                        lastSyncDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                        lastModified: sqlite3_column_type(stmt, 3) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)) : nil,
                        itemCount: Int(sqlite3_column_int64(stmt, 4))
                    )
                )
            }
            return cursors
        }
    }
}

// MARK: - Coursework Tracking Operations

extension Database {
    public func saveAssignments(_ assignments: [MoodleAssignment], siteID: String) throws {
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                try deleteForSite("assignments", siteID: siteID)
                let sql = """
                    INSERT OR REPLACE INTO assignments (id, site_id, course_id, name, due_date, cutoff_date, submitted, graded, grade)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """
                for a in assignments {
                    let stmt = try prepareStatement(sql)
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_int64(stmt, 1, Int64(a.id))
                    sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 3, Int64(a.courseID))
                    sqlite3_bind_text(stmt, 4, (a.name as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    bindOptionalDate(stmt, 5, a.dueDate)
                    bindOptionalDate(stmt, 6, a.cutoffDate)
                    sqlite3_bind_int(stmt, 7, a.submitted ? 1 : 0)
                    sqlite3_bind_int(stmt, 8, a.graded ? 1 : 0)
                    bindOptionalText(stmt, 9, a.grade)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw FindleError.databaseError(detail: "saveAssignments: \(String(cString: sqlite3_errmsg(db)))")
                    }
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    public func fetchAssignments(siteID: String) throws -> [MoodleAssignment] {
        try queue.sync {
            let stmt = try prepareStatement("SELECT id, course_id, name, due_date, cutoff_date, submitted, graded, grade FROM assignments WHERE site_id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            var out: [MoodleAssignment] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(MoodleAssignment(
                    id: Int(sqlite3_column_int64(stmt, 0)),
                    courseID: Int(sqlite3_column_int64(stmt, 1)),
                    name: String(cString: sqlite3_column_text(stmt, 2)),
                    dueDate: Self.columnDate(stmt, 3),
                    cutoffDate: Self.columnDate(stmt, 4),
                    submitted: sqlite3_column_int(stmt, 5) == 1,
                    graded: sqlite3_column_int(stmt, 6) == 1,
                    grade: sqlite3_column_text(stmt, 7).map { String(cString: $0) }
                ))
            }
            return out
        }
    }

    public func saveGradeItems(_ items: [MoodleGradeItem], siteID: String) throws {
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                try deleteForSite("grade_items", siteID: siteID)
                let sql = """
                    INSERT OR REPLACE INTO grade_items (id, site_id, course_id, item_name, grade, percentage, feedback)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """
                for g in items {
                    let stmt = try prepareStatement(sql)
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_int64(stmt, 1, Int64(g.id))
                    sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 3, Int64(g.courseID))
                    sqlite3_bind_text(stmt, 4, (g.itemName as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    bindOptionalText(stmt, 5, g.grade)
                    bindOptionalText(stmt, 6, g.percentage)
                    bindOptionalText(stmt, 7, g.feedback)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw FindleError.databaseError(detail: "saveGradeItems: \(String(cString: sqlite3_errmsg(db)))")
                    }
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    public func fetchGradeItems(siteID: String) throws -> [MoodleGradeItem] {
        try queue.sync {
            let stmt = try prepareStatement("SELECT id, course_id, item_name, grade, percentage, feedback FROM grade_items WHERE site_id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            var out: [MoodleGradeItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(MoodleGradeItem(
                    id: Int(sqlite3_column_int64(stmt, 0)),
                    courseID: Int(sqlite3_column_int64(stmt, 1)),
                    itemName: String(cString: sqlite3_column_text(stmt, 2)),
                    grade: sqlite3_column_text(stmt, 3).map { String(cString: $0) },
                    percentage: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
                    feedback: sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                ))
            }
            return out
        }
    }

    public func saveQuizzes(_ quizzes: [MoodleQuiz], siteID: String) throws {
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                try deleteForSite("quizzes", siteID: siteID)
                let sql = """
                    INSERT OR REPLACE INTO quizzes (id, site_id, course_id, name, open_date, close_date, time_limit)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                """
                for q in quizzes {
                    let stmt = try prepareStatement(sql)
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_int64(stmt, 1, Int64(q.id))
                    sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 3, Int64(q.courseID))
                    sqlite3_bind_text(stmt, 4, (q.name as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    bindOptionalDate(stmt, 5, q.openDate)
                    bindOptionalDate(stmt, 6, q.closeDate)
                    if let t = q.timeLimit { sqlite3_bind_int64(stmt, 7, Int64(t)) } else { sqlite3_bind_null(stmt, 7) }
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw FindleError.databaseError(detail: "saveQuizzes: \(String(cString: sqlite3_errmsg(db)))")
                    }
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    public func fetchQuizzes(siteID: String) throws -> [MoodleQuiz] {
        try queue.sync {
            let stmt = try prepareStatement("SELECT id, course_id, name, open_date, close_date, time_limit FROM quizzes WHERE site_id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            var out: [MoodleQuiz] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(MoodleQuiz(
                    id: Int(sqlite3_column_int64(stmt, 0)),
                    courseID: Int(sqlite3_column_int64(stmt, 1)),
                    name: String(cString: sqlite3_column_text(stmt, 2)),
                    openDate: Self.columnDate(stmt, 3),
                    closeDate: Self.columnDate(stmt, 4),
                    timeLimit: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int64(stmt, 5)) : nil
                ))
            }
            return out
        }
    }

    public func saveQuizAttempts(_ attempts: [MoodleQuizAttempt], siteID: String) throws {
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                try deleteForSite("quiz_attempts", siteID: siteID)
                let sql = """
                    INSERT OR REPLACE INTO quiz_attempts (id, site_id, quiz_id, attempt_number, state, sum_grades, start_time, finish_time)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
                for a in attempts {
                    let stmt = try prepareStatement(sql)
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_int64(stmt, 1, Int64(a.id))
                    sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 3, Int64(a.quizID))
                    sqlite3_bind_int64(stmt, 4, Int64(a.attemptNumber))
                    sqlite3_bind_text(stmt, 5, (a.state as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    if let s = a.sumGrades { sqlite3_bind_double(stmt, 6, s) } else { sqlite3_bind_null(stmt, 6) }
                    bindOptionalDate(stmt, 7, a.startTime)
                    bindOptionalDate(stmt, 8, a.finishTime)
                    guard sqlite3_step(stmt) == SQLITE_DONE else {
                        throw FindleError.databaseError(detail: "saveQuizAttempts: \(String(cString: sqlite3_errmsg(db)))")
                    }
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    public func fetchQuizAttempts(siteID: String) throws -> [MoodleQuizAttempt] {
        try queue.sync {
            let stmt = try prepareStatement("SELECT id, quiz_id, attempt_number, state, sum_grades, start_time, finish_time FROM quiz_attempts WHERE site_id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            var out: [MoodleQuizAttempt] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(MoodleQuizAttempt(
                    id: Int(sqlite3_column_int64(stmt, 0)),
                    quizID: Int(sqlite3_column_int64(stmt, 1)),
                    attemptNumber: Int(sqlite3_column_int64(stmt, 2)),
                    state: String(cString: sqlite3_column_text(stmt, 3)),
                    sumGrades: sqlite3_column_type(stmt, 4) != SQLITE_NULL ? sqlite3_column_double(stmt, 4) : nil,
                    startTime: Self.columnDate(stmt, 5),
                    finishTime: Self.columnDate(stmt, 6)
                ))
            }
            return out
        }
    }

    // MARK: Tracking helpers (call inside `queue.sync`)

    private func deleteForSite(_ table: String, siteID: String) throws {
        let stmt = try prepareStatement("DELETE FROM \(table) WHERE site_id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw FindleError.databaseError(detail: "deleteForSite(\(table)): \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    private func bindOptionalDate(_ stmt: OpaquePointer?, _ index: Int32, _ date: Date?) {
        if let date { sqlite3_bind_double(stmt, index, date.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, index) }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ text: String?) {
        if let text { sqlite3_bind_text(stmt, index, (text as NSString).utf8String, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(stmt, index) }
    }

    private static func columnDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        sqlite3_column_type(stmt, index) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, index)) : nil
    }
}

// MARK: - Maintenance

extension Database {
    public func rebuildIndex() throws {
        try execute("REINDEX")
        logger.info("Database index rebuilt")
    }

    public func vacuum() throws {
        try execute("VACUUM")
        logger.info("Database vacuumed")
    }

    public func deleteAllData() throws {
        try queue.sync {
            try executeUnsafe("BEGIN IMMEDIATE TRANSACTION")
            do {
                for table in [
                    "items", "pending_deletions", "course_tags", "sync_cursors",
                    "course_outlines",
                    "assignments", "grade_items", "quizzes", "quiz_attempts",
                    "courses", "accounts", "sites"
                ] {
                    try executeUnsafe("DELETE FROM \(table)")
                }
                // The change counter is never reset. File Provider anchors are
                // counter values, and a counter that moves backwards would make
                // the extension skip changes. Only the seed marker is cleared.
                try executeUnsafe("UPDATE system_metadata SET value = 0 WHERE key = 'seed_complete'")
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
        logger.info("All database data deleted")
    }
}
