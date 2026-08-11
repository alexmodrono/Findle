// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SQLite3
import OSLog
import SharedDomain

// Tells SQLite to make its own copy of the bound data during the bind call,
// so the source buffer's lifetime doesn't have to outlive sqlite3_step. The
// default (nil) is SQLITE_STATIC, which is unsafe when the source is an
// autoreleased NSString.utf8String buffer or a transient Swift String.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    public static let schemaVersion = 13

    /// Opens the database.
    ///
    /// - Parameter readOnly: when `true`, opens as a pure reader and skips all
    ///   schema creation/migration. Used by the MCP server, a third reader on
    ///   the shared WAL database — the app remains the single writer.
    ///
    ///   The handle is opened `READWRITE` (not `READONLY`) on purpose: a true
    ///   `SQLITE_OPEN_READONLY` connection cannot reliably read rows still in the
    ///   `-wal` file (it sees only the last checkpoint), so it would miss data
    ///   the live app hasn't checkpointed yet. `PRAGMA query_only = ON` then
    ///   makes any write attempt an error, preserving read-only semantics while
    ///   getting full WAL visibility.
    public init(path: String? = nil, readOnly: Bool = false) throws {
        if let path = path {
            self.path = path
        } else {
            let fm = FileManager.default
            let appSupport: URL
            if let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier) {
                let preferredAppSupport = groupURL.appendingPathComponent("Application Support", isDirectory: true)
                let legacyAppSupport = groupURL
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)

                try Self.migrateLegacyDatabaseIfNeeded(
                    from: legacyAppSupport,
                    to: preferredAppSupport,
                    fileManager: fm
                )

                appSupport = preferredAppSupport
            } else {
                appSupport = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                    .appendingPathComponent("Library", isDirectory: true)
                    .appendingPathComponent("Application Support", isDirectory: true)
            }
            let dbDir = appSupport.appendingPathComponent("Findle", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            self.path = dbDir.appendingPathComponent("findle.db").path
        }

        var dbPointer: OpaquePointer?
        let flags = readOnly
            ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let status = sqlite3_open_v2(self.path, &dbPointer, flags, nil)
        guard status == SQLITE_OK, let pointer = dbPointer else {
            let message = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw FindleError.databaseError(detail: "Could not open database: \(message)")
        }
        self.db = pointer

        // Wait up to 5s on SQLITE_BUSY before failing. With the File Provider
        // extension reading concurrently under WAL, lock contention is normal
        // and short retries inside SQLite are cheaper than surfacing errors.
        sqlite3_busy_timeout(pointer, 5000)

        if readOnly {
            // A pure reader: don't touch journal mode (can't, on a read-only
            // handle) and never create or migrate the schema. `query_only`
            // turns any accidental write into an error rather than a silent
            // mutation of the app's database.
            try execute("PRAGMA query_only = ON")
            logger.info("Database opened read-only at \(self.path, privacy: .public)")
            return
        }

        // Enable WAL mode for better concurrent performance
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")

        try createSchema()
        try migrateSchema()
        logger.info("Database opened at \(self.path, privacy: .public)")
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

        for suffix in ["", "-wal", "-shm"] {
            let sourceURL = legacyDatabaseURL.deletingLastPathComponent()
                .appendingPathComponent("findle.db\(suffix)")
            let destinationURL = preferredDirectory.appendingPathComponent("findle.db\(suffix)")

            guard fileManager.fileExists(atPath: sourceURL.path) else { continue }
            guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }

            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        }
    }

    // MARK: - Schema

    private func createSchema() throws {
        try execute("""
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

        try execute("""
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

        try execute("""
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

        try execute("""
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

        try execute("""
            CREATE TABLE IF NOT EXISTS sync_cursors (
                course_id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                last_sync_date REAL NOT NULL,
                last_modified REAL,
                item_count INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (course_id, site_id)
            )
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS course_tags (
                course_id INTEGER NOT NULL,
                site_id TEXT NOT NULL,
                tag_name TEXT NOT NULL,
                tag_color INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (course_id, site_id, tag_name)
            )
        """)

        // MARK: Read-only coursework tracking (deadlines, grades, quizzes)

        try execute("""
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

        try execute("""
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

        try execute("""
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

        try execute("""
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

        try execute("""
            CREATE TABLE IF NOT EXISTS pending_deletions (
                item_id TEXT PRIMARY KEY,
                deleted_at REAL NOT NULL DEFAULT (strftime('%s', 'now')),
                deleted_at_counter INTEGER NOT NULL DEFAULT 0
            )
        """)

        try execute("""
            CREATE TABLE IF NOT EXISTS system_metadata (
                key TEXT PRIMARY KEY,
                value INTEGER NOT NULL
            )
        """)
        try execute("INSERT OR IGNORE INTO system_metadata (key, value) VALUES ('change_counter', 0)")

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parent_id)
        """)

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_items_course ON items(course_id, site_id)
        """)

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_items_sync_state ON items(sync_state)
        """)

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_items_pinned ON items(site_id, is_pinned) WHERE is_pinned = 1
        """)
    }

    private func migrateSchema() throws {
        // Read the current user_version pragma.
        let currentVersion: Int32 = try queue.sync {
            let stmt = try prepareStatement("PRAGMA user_version")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int(stmt, 0)
        }

        if currentVersion < 2 {
            // v1 -> v2: add login_type and launch_url columns to sites.
            let columns = try existingColumns(table: "sites")
            if !columns.contains("login_type") {
                try execute("ALTER TABLE sites ADD COLUMN login_type INTEGER NOT NULL DEFAULT 1")
            }
            if !columns.contains("launch_url") {
                try execute("ALTER TABLE sites ADD COLUMN launch_url TEXT")
            }
            logger.info("Migrated database schema to version 2")
        }

        if currentVersion < 3 {
            // v2 -> v3: add wwwroot, httpswwwroot, show_login_form columns to sites.
            let columns = try existingColumns(table: "sites")
            if !columns.contains("wwwroot") {
                try execute("ALTER TABLE sites ADD COLUMN wwwroot TEXT")
            }
            if !columns.contains("httpswwwroot") {
                try execute("ALTER TABLE sites ADD COLUMN httpswwwroot TEXT")
            }
            if !columns.contains("show_login_form") {
                try execute("ALTER TABLE sites ADD COLUMN show_login_form INTEGER NOT NULL DEFAULT 1")
            }
            logger.info("Migrated database schema to version 3")
        }

        if currentVersion < 4 {
            let courseColumns = try existingColumns(table: "courses")
            if !courseColumns.contains("custom_folder_name") {
                try execute("ALTER TABLE courses ADD COLUMN custom_folder_name TEXT")
            }

            let itemColumns = try existingColumns(table: "items")
            if !itemColumns.contains("tag_data") {
                try execute("ALTER TABLE items ADD COLUMN tag_data BLOB")
            }

            logger.info("Migrated database schema to version 4")
        }

        if currentVersion < 5 {
            // Fix tag color indices: old values had red=7, orange=6.
            // Correct values: red=6, orange=7. Swap them.
            try execute("UPDATE course_tags SET tag_color = -1 WHERE tag_color = 6")
            try execute("UPDATE course_tags SET tag_color = 6 WHERE tag_color = 7")
            try execute("UPDATE course_tags SET tag_color = 7 WHERE tag_color = -1")
            logger.info("Migrated database schema to version 5 (fixed tag colors)")
        }

        if currentVersion < 6 {
            // v5 -> v6: pending_deletions table created in createSchema().
            logger.info("Migrated database schema to version 6 (pending deletions)")
        }

        if currentVersion < 7 {
            let courseColumns = try existingColumns(table: "courses")
            if !courseColumns.contains("custom_icon_name") {
                try execute("ALTER TABLE courses ADD COLUMN custom_icon_name TEXT")
            }
            logger.info("Migrated database schema to version 7 (custom course icons)")
        }

        if currentVersion < 8 {
            let itemColumns = try existingColumns(table: "items")
            if !itemColumns.contains("is_local") {
                try execute("ALTER TABLE items ADD COLUMN is_local INTEGER NOT NULL DEFAULT 0")
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
            try execute("""
                CREATE TABLE pending_deletions_new (
                    item_id TEXT PRIMARY KEY,
                    deleted_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
                )
            """)
            try execute("INSERT OR IGNORE INTO pending_deletions_new SELECT item_id, deleted_at FROM pending_deletions")
            try execute("DROP TABLE pending_deletions")
            try execute("ALTER TABLE pending_deletions_new RENAME TO pending_deletions")
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
                try execute("ALTER TABLE items ADD COLUMN updated_at INTEGER NOT NULL DEFAULT 0")
            }
            let pendingColumns = try existingColumns(table: "pending_deletions")
            if !pendingColumns.contains("deleted_at_counter") {
                try execute("ALTER TABLE pending_deletions ADD COLUMN deleted_at_counter INTEGER NOT NULL DEFAULT 0")
            }
            try execute("""
                CREATE TABLE IF NOT EXISTS system_metadata (
                    key TEXT PRIMARY KEY,
                    value INTEGER NOT NULL
                )
            """)
            try execute("INSERT OR IGNORE INTO system_metadata (key, value) VALUES ('change_counter', 0)")

            // Seed updated_at for existing items so they're treated as having
            // changed once at migration time, and advance the counter past
            // every existing row so future writes get unique values. Same for
            // pre-existing pending_deletions rows.
            try execute("UPDATE items SET updated_at = rowid WHERE updated_at = 0")
            try execute("UPDATE pending_deletions SET deleted_at_counter = (SELECT COALESCE(MAX(updated_at), 0) FROM items) + rowid WHERE deleted_at_counter = 0")
            try execute("""
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

            try execute("CREATE INDEX IF NOT EXISTS idx_items_updated_at ON items(updated_at)")
            try execute("CREATE INDEX IF NOT EXISTS idx_pending_deletions_counter ON pending_deletions(deleted_at_counter)")
            try execute("""
                CREATE TRIGGER IF NOT EXISTS items_bump_after_insert
                AFTER INSERT ON items
                WHEN NEW.updated_at = 0
                BEGIN
                    UPDATE system_metadata SET value = value + 1 WHERE key = 'change_counter';
                    UPDATE items SET updated_at = (SELECT value FROM system_metadata WHERE key = 'change_counter') WHERE id = NEW.id;
                END
            """)
            try execute("""
                CREATE TRIGGER IF NOT EXISTS items_bump_after_update
                AFTER UPDATE OF parent_id, filename, file_size, sync_state, is_pinned, local_path, remote_url, content_version, tag_data, is_local, modification_date
                ON items
                BEGIN
                    UPDATE system_metadata SET value = value + 1 WHERE key = 'change_counter';
                    UPDATE items SET updated_at = (SELECT value FROM system_metadata WHERE key = 'change_counter') WHERE id = NEW.id;
                END
            """)
            try execute("""
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
                try execute("ALTER TABLE courses ADD COLUMN image_url TEXT")
            }
            logger.info("Migrated database schema to version 12 (course cover images)")
        }

        if currentVersion < 13 {
            // v12 -> v13: read-only coursework tracking tables (assignments,
            // grade_items, quizzes, quiz_attempts). Created in createSchema()
            // with IF NOT EXISTS, so this is just the version marker.
            logger.info("Migrated database schema to version 13 (coursework tracking)")
        }

        try execute("PRAGMA user_version = \(Self.schemaVersion)")
    }

    /// Regenerate tag_data blobs for all course items from course_tags table.
    private func regenerateAllTagData() throws {
        try queue.sync {
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
                _ = sqlite3_step(updateStmt)
            }
        }
    }

    private func existingColumns(table: String) throws -> Set<String> {
        try queue.sync {
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
            throw FindleError.databaseError(detail: message)
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
            INSERT OR REPLACE INTO sites (id, display_name, base_url, supports_web_services,
                supports_mobile_api, supports_file_download, moodle_version, moodle_release, site_name,
                login_type, launch_url, wwwroot, httpswwwroot, show_login_form)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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

            return MoodleSite(
                id: String(cString: sqlite3_column_text(stmt, 0)),
                displayName: String(cString: sqlite3_column_text(stmt, 1)),
                baseURL: URL(string: String(cString: sqlite3_column_text(stmt, 2)))!,
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
            while sqlite3_step(stmt) == SQLITE_ROW {
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
            }
            return accounts
        }
    }

    public func deleteAccount(id: String) throws {
        try queue.sync {
            let deleteItems = try prepareStatement("DELETE FROM items WHERE site_id IN (SELECT site_id FROM accounts WHERE id = ?)")
            defer { sqlite3_finalize(deleteItems) }
            sqlite3_bind_text(deleteItems, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(deleteItems)

            let deleteAccount = try prepareStatement("DELETE FROM accounts WHERE id = ?")
            defer { sqlite3_finalize(deleteAccount) }
            sqlite3_bind_text(deleteAccount, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            _ = sqlite3_step(deleteAccount)
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
            try executeUnsafe("BEGIN TRANSACTION")
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
            _ = sqlite3_step(stmt)
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

// MARK: - Course Tag Operations

extension Database {
    public func saveCourseTags(_ tags: [FinderTag], courseID: Int, siteID: String) throws {
        try queue.sync {
            try executeUnsafe("BEGIN TRANSACTION")
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
        let sql = """
            INSERT OR REPLACE INTO items (id, parent_id, site_id, course_id, remote_id,
                filename, is_directory, content_type, file_size, creation_date,
                modification_date, sync_state, is_pinned, local_path, remote_url, content_version, tag_data, is_local)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try queue.sync {
            try executeUnsafe("BEGIN TRANSACTION")
            do {
                for item in items {
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
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
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

    public func fetchItem(id: String) throws -> LocalItem? {
        let sql = "SELECT * FROM items WHERE id = ?"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readItem(from: stmt)
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
        let sql = "UPDATE items SET filename = ? WHERE id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (filename as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FindleError.databaseError(detail: "Failed to update item filename")
            }
        }
    }

    public func updateItemTagData(id: String, tagData: Data?) throws {
        let sql = "UPDATE items SET tag_data = ? WHERE id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            if let td = tagData {
                sqlite3_bind_blob(stmt, 1, (td as NSData).bytes, Int32(td.count), SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, SQLITE_TRANSIENT)
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
            _ = sqlite3_step(stmt)
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
        try queue.sync {
            try executeUnsafe("BEGIN TRANSACTION")
            do {
                // Record IDs for the File Provider to report as deletions (skip local items).
                // Append to any pending deletions from prior cycles that haven't drained yet —
                // do NOT wipe the table blindly or earlier course deletions would be lost.
                let insertStmt = try prepareStatement("INSERT OR IGNORE INTO pending_deletions (item_id) SELECT id FROM items WHERE course_id = ? AND site_id = ? AND is_local = 0")
                defer { sqlite3_finalize(insertStmt) }
                sqlite3_bind_int(insertStmt, 1, Int32(courseID))
                sqlite3_bind_text(insertStmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw FindleError.databaseError(detail: "deleteItems pending insert failed")
                }

                let deleteStmt = try prepareStatement("DELETE FROM items WHERE course_id = ? AND site_id = ? AND is_local = 0")
                defer { sqlite3_finalize(deleteStmt) }
                sqlite3_bind_int(deleteStmt, 1, Int32(courseID))
                sqlite3_bind_text(deleteStmt, 2, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                    throw FindleError.databaseError(detail: "deleteItems delete failed")
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    public func deleteAllItems(siteID: String) throws {
        try queue.sync {
            try executeUnsafe("BEGIN TRANSACTION")
            do {
                let insertStmt = try prepareStatement("INSERT OR IGNORE INTO pending_deletions (item_id) SELECT id FROM items WHERE site_id = ? AND is_local = 0")
                defer { sqlite3_finalize(insertStmt) }
                sqlite3_bind_text(insertStmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(insertStmt) == SQLITE_DONE else {
                    throw FindleError.databaseError(detail: "deleteAllItems pending insert failed")
                }

                let deleteStmt = try prepareStatement("DELETE FROM items WHERE site_id = ? AND is_local = 0")
                defer { sqlite3_finalize(deleteStmt) }
                sqlite3_bind_text(deleteStmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                    throw FindleError.databaseError(detail: "deleteAllItems delete failed")
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    /// Delete the given items (and their descendants) and record a tombstone
    /// in `pending_deletions` so the File Provider extension can report the
    /// deletion to Finder on the next change enumeration. All work happens in
    /// a single transaction so partial failures don't leak rows.
    public func deleteItemsWithTombstone(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try queue.sync {
            try executeUnsafe("BEGIN TRANSACTION")
            do {
                var idsToDelete = Set(ids)
                var frontier = Array(ids)

                while !frontier.isEmpty {
                    var nextFrontier: [String] = []
                    let childStmt = try prepareStatement("SELECT id FROM items WHERE parent_id = ?")
                    defer { sqlite3_finalize(childStmt) }
                    for parentID in frontier {
                        sqlite3_reset(childStmt)
                        sqlite3_bind_text(childStmt, 1, (parentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                        while sqlite3_step(childStmt) == SQLITE_ROW {
                            let childID = String(cString: sqlite3_column_text(childStmt, 0))
                            if idsToDelete.insert(childID).inserted {
                                nextFrontier.append(childID)
                            }
                        }
                    }
                    frontier = nextFrontier
                }

                let tombstoneStmt = try prepareStatement("INSERT OR IGNORE INTO pending_deletions (item_id) VALUES (?)")
                defer { sqlite3_finalize(tombstoneStmt) }
                let deleteStmt = try prepareStatement("DELETE FROM items WHERE id = ?")
                defer { sqlite3_finalize(deleteStmt) }

                for itemID in idsToDelete {
                    sqlite3_reset(tombstoneStmt)
                    sqlite3_bind_text(tombstoneStmt, 1, (itemID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    guard sqlite3_step(tombstoneStmt) == SQLITE_DONE else {
                        throw FindleError.databaseError(detail: "deleteItemsWithTombstone tombstone failed")
                    }
                    sqlite3_reset(deleteStmt)
                    sqlite3_bind_text(deleteStmt, 1, (itemID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    guard sqlite3_step(deleteStmt) == SQLITE_DONE else {
                        throw FindleError.databaseError(detail: "deleteItemsWithTombstone delete failed")
                    }
                }
                try executeUnsafe("COMMIT")
            } catch {
                try? executeUnsafe("ROLLBACK")
                throw error
            }
        }
    }

    /// Delete a single item and all its children by ID.
    public func deleteItemAndChildren(id: String) throws {
        try queue.sync {
            // Delete children first (recursive via parent_id chain).
            // For simplicity, collect all descendant IDs then delete them.
            var idsToDelete = [id]
            var frontier = [id]

            while !frontier.isEmpty {
                var nextFrontier: [String] = []
                for parentID in frontier {
                    let stmt = try prepareStatement("SELECT id FROM items WHERE parent_id = ?")
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, (parentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let childID = String(cString: sqlite3_column_text(stmt, 0))
                        idsToDelete.append(childID)
                        nextFrontier.append(childID)
                    }
                }
                frontier = nextFrontier
            }

            for itemID in idsToDelete {
                let stmt = try prepareStatement("DELETE FROM items WHERE id = ?")
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (itemID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                _ = sqlite3_step(stmt)
            }
        }
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

    /// Return the global monotonic change counter. The value is bumped by SQL
    /// triggers on writes to `items` and `pending_deletions`, so it's safe to
    /// use as a sync anchor handed to NSFileProviderChangeObserver.
    public func currentChangeCounter() throws -> Int64 {
        try queue.sync {
            let stmt = try prepareStatement("SELECT value FROM system_metadata WHERE key = 'change_counter'")
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
    }

    /// Return items in a container whose `updated_at` is strictly greater than `anchor`.
    /// Pass `parentID == nil` for root items, or a parent ID for a single container.
    public func fetchItemsChangedSince(anchor: Int64, parentID: String?) throws -> [LocalItem] {
        let sql: String
        if parentID == nil {
            sql = "SELECT * FROM items WHERE parent_id IS NULL AND updated_at > ? ORDER BY updated_at"
        } else {
            sql = "SELECT * FROM items WHERE parent_id = ? AND updated_at > ? ORDER BY updated_at"
        }
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            if let parentID {
                sqlite3_bind_text(stmt, 1, (parentID as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, anchor)
            } else {
                sqlite3_bind_int64(stmt, 1, anchor)
            }
            return try readItems(from: stmt)
        }
    }

    /// Return all items for a site whose `updated_at` is strictly greater than `anchor`.
    public func fetchItemsChangedSince(anchor: Int64, siteID: String) throws -> [LocalItem] {
        let sql = "SELECT * FROM items WHERE site_id = ? AND updated_at > ? ORDER BY updated_at"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, anchor)
            return try readItems(from: stmt)
        }
    }

    /// Pending-deletion IDs whose `deleted_at_counter` is strictly greater
    /// than `anchor`. Returned in counter order so the enumerator can derive
    /// the next anchor from the last entry.
    public func fetchPendingDeletionsSince(anchor: Int64) throws -> [String] {
        let sql = "SELECT item_id FROM pending_deletions WHERE deleted_at_counter > ? ORDER BY deleted_at_counter"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, anchor)
            var ids: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                ids.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
            return ids
        }
    }

    public func clearPendingDeletions() throws {
        try execute("DELETE FROM pending_deletions")
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

        let isLocal = colCount > 17 ? sqlite3_column_int(stmt, 17) == 1 : false

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
}

// MARK: - Sync Cursor Operations

extension Database {
    public func saveSyncCursor(_ cursor: SyncCursor) throws {
        let sql = """
            INSERT OR REPLACE INTO sync_cursors (course_id, site_id, last_sync_date, last_modified, item_count)
            VALUES (?, ?, ?, ?, ?)
        """
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, Int64(cursor.courseID))
            sqlite3_bind_text(stmt, 2, (cursor.siteID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 3, cursor.lastSyncDate.timeIntervalSince1970)
            if let lm = cursor.lastModified { sqlite3_bind_double(stmt, 4, lm.timeIntervalSince1970) }
            sqlite3_bind_int64(stmt, 5, Int64(cursor.itemCount))

            _ = sqlite3_step(stmt)
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
            try executeUnsafe("BEGIN TRANSACTION")
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
            try executeUnsafe("BEGIN TRANSACTION")
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
            try executeUnsafe("BEGIN TRANSACTION")
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
            try executeUnsafe("BEGIN TRANSACTION")
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
        try execute("DELETE FROM items")
        try execute("DELETE FROM sync_cursors")
        try execute("DELETE FROM courses")
        try execute("DELETE FROM accounts")
        try execute("DELETE FROM sites")
        logger.info("All database data deleted")
    }
}
