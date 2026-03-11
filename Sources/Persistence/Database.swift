import Foundation
import SQLite3
import OSLog
import SharedDomain

/// SQLite database manager for Foodle's local persistence.
public final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "es.amodrono.foodle.persistence.db", qos: .userInitiated)
    private let logger = Logger(subsystem: "es.amodrono.foodle.persistence", category: "Database")
    private let path: String

    public static let schemaVersion = 1

    public init(path: String? = nil) throws {
        if let path = path {
            self.path = path
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDir = appSupport.appendingPathComponent("Foodle", isDirectory: true)
            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
            self.path = dbDir.appendingPathComponent("foodle.db").path
        }

        var dbPointer: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(self.path, &dbPointer, flags, nil)
        guard status == SQLITE_OK, let pointer = dbPointer else {
            let message = dbPointer.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            throw FoodleError.databaseError(detail: "Could not open database: \(message)")
        }
        self.db = pointer

        // Enable WAL mode for better concurrent performance
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA foreign_keys = ON")

        try createSchema()
        logger.info("Database opened at \(self.path, privacy: .public)")
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
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
                created_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
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
                content_version TEXT
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
            CREATE INDEX IF NOT EXISTS idx_items_parent ON items(parent_id)
        """)

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_items_course ON items(course_id, site_id)
        """)

        try execute("""
            CREATE INDEX IF NOT EXISTS idx_items_sync_state ON items(sync_state)
        """)
    }

    // MARK: - Execution

    func execute(_ sql: String) throws {
        try queue.sync {
            var errorMessage: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(db, sql, nil, nil, &errorMessage)
            if status != SQLITE_OK {
                let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
                sqlite3_free(errorMessage)
                throw FoodleError.databaseError(detail: message)
            }
        }
    }

    func prepareStatement(_ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard status == SQLITE_OK, let statement = stmt else {
            let message = String(cString: sqlite3_errmsg(db))
            throw FoodleError.databaseError(detail: "Prepare failed: \(message)")
        }
        return statement
    }
}

// MARK: - Site Operations

extension Database {
    public func saveSite(_ site: MoodleSite) throws {
        let sql = """
            INSERT OR REPLACE INTO sites (id, display_name, base_url, supports_web_services,
                supports_mobile_api, supports_file_download, moodle_version, moodle_release, site_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_text(stmt, 1, (site.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (site.displayName as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (site.baseURL.absoluteString as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 4, site.capabilities.supportsWebServices ? 1 : 0)
            sqlite3_bind_int(stmt, 5, site.capabilities.supportsMobileAPI ? 1 : 0)
            sqlite3_bind_int(stmt, 6, site.capabilities.supportsFileDownload ? 1 : 0)
            if let v = site.capabilities.moodleVersion { sqlite3_bind_text(stmt, 7, (v as NSString).utf8String, -1, nil) }
            if let r = site.capabilities.moodleRelease { sqlite3_bind_text(stmt, 8, (r as NSString).utf8String, -1, nil) }
            if let n = site.capabilities.siteName { sqlite3_bind_text(stmt, 9, (n as NSString).utf8String, -1, nil) }

            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FoodleError.databaseError(detail: "Failed to save site: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
    }

    public func fetchSite(id: String) throws -> MoodleSite? {
        let sql = "SELECT * FROM sites WHERE id = ?"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

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
                    siteName: sqlite3_column_text(stmt, 8).map { String(cString: $0) }
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

            sqlite3_bind_text(stmt, 1, (account.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (account.siteID as NSString).utf8String, -1, nil)
            if let uid = account.userID { sqlite3_bind_int64(stmt, 3, Int64(uid)) }
            sqlite3_bind_text(stmt, 4, (String(describing: account.state) as NSString).utf8String, -1, nil)
            if let sync = account.lastSyncDate { sqlite3_bind_double(stmt, 5, sync.timeIntervalSince1970) }
            sqlite3_bind_double(stmt, 6, account.createdAt.timeIntervalSince1970)

            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FoodleError.databaseError(detail: "Failed to save account")
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
        try execute("DELETE FROM accounts WHERE id = '\(id)'")
        try execute("DELETE FROM items WHERE site_id IN (SELECT site_id FROM accounts WHERE id = '\(id)')")
    }
}

// MARK: - Course Operations

extension Database {
    public func saveCourses(_ courses: [MoodleCourse]) throws {
        let sql = """
            INSERT OR REPLACE INTO courses (id, site_id, short_name, full_name, summary,
                category_id, start_date, end_date, last_accessed, visible)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try queue.sync {
            try execute("BEGIN TRANSACTION")
            for course in courses {
                let stmt = try prepareStatement(sql)
                defer { sqlite3_finalize(stmt) }

                sqlite3_bind_int64(stmt, 1, Int64(course.id))
                sqlite3_bind_text(stmt, 2, (course.siteID as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (course.shortName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (course.fullName as NSString).utf8String, -1, nil)
                if let s = course.summary { sqlite3_bind_text(stmt, 5, (s as NSString).utf8String, -1, nil) }
                if let c = course.categoryID { sqlite3_bind_int64(stmt, 6, Int64(c)) }
                if let d = course.startDate { sqlite3_bind_double(stmt, 7, d.timeIntervalSince1970) }
                if let d = course.endDate { sqlite3_bind_double(stmt, 8, d.timeIntervalSince1970) }
                if let d = course.lastAccessed { sqlite3_bind_double(stmt, 9, d.timeIntervalSince1970) }
                sqlite3_bind_int(stmt, 10, course.visible ? 1 : 0)

                _ = sqlite3_step(stmt)
            }
            try execute("COMMIT")
        }
    }

    public func fetchCourses(siteID: String) throws -> [MoodleCourse] {
        let sql = "SELECT * FROM courses WHERE site_id = ? ORDER BY full_name"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, nil)

            var courses: [MoodleCourse] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
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
                    siteID: siteID
                ))
            }
            return courses
        }
    }

    public func updateCourseSubscription(courseID: Int, siteID: String, state: CourseSubscriptionState) throws {
        try execute("UPDATE courses SET subscription_state = '\(state.rawValue)' WHERE id = \(courseID) AND site_id = '\(siteID)'")
    }
}

// MARK: - Item Operations

extension Database {
    public func saveItems(_ items: [LocalItem]) throws {
        let sql = """
            INSERT OR REPLACE INTO items (id, parent_id, site_id, course_id, remote_id,
                filename, is_directory, content_type, file_size, creation_date,
                modification_date, sync_state, is_pinned, local_path, remote_url, content_version)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try queue.sync {
            try execute("BEGIN TRANSACTION")
            for item in items {
                let stmt = try prepareStatement(sql)
                defer { sqlite3_finalize(stmt) }

                sqlite3_bind_text(stmt, 1, (item.id as NSString).utf8String, -1, nil)
                if let p = item.parentID { sqlite3_bind_text(stmt, 2, (p as NSString).utf8String, -1, nil) }
                sqlite3_bind_text(stmt, 3, (item.siteID as NSString).utf8String, -1, nil)
                sqlite3_bind_int64(stmt, 4, Int64(item.courseID))
                sqlite3_bind_int64(stmt, 5, Int64(item.remoteID))
                sqlite3_bind_text(stmt, 6, (item.filename as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 7, item.isDirectory ? 1 : 0)
                if let ct = item.contentType { sqlite3_bind_text(stmt, 8, (ct as NSString).utf8String, -1, nil) }
                sqlite3_bind_int64(stmt, 9, item.fileSize)
                if let d = item.creationDate { sqlite3_bind_double(stmt, 10, d.timeIntervalSince1970) }
                if let d = item.modificationDate { sqlite3_bind_double(stmt, 11, d.timeIntervalSince1970) }
                sqlite3_bind_text(stmt, 12, (item.syncState.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 13, item.isPinned ? 1 : 0)
                if let lp = item.localPath { sqlite3_bind_text(stmt, 14, (lp as NSString).utf8String, -1, nil) }
                if let ru = item.remoteURL { sqlite3_bind_text(stmt, 15, (ru.absoluteString as NSString).utf8String, -1, nil) }
                if let cv = item.contentVersion { sqlite3_bind_text(stmt, 16, (cv as NSString).utf8String, -1, nil) }

                _ = sqlite3_step(stmt)
            }
            try execute("COMMIT")
        }
    }

    public func fetchItems(parentID: String?) throws -> [LocalItem] {
        let sql: String
        if let parentID = parentID {
            sql = "SELECT * FROM items WHERE parent_id = '\(parentID)' ORDER BY is_directory DESC, filename"
        } else {
            sql = "SELECT * FROM items WHERE parent_id IS NULL ORDER BY is_directory DESC, filename"
        }

        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            return try readItems(from: stmt)
        }
    }

    public func fetchItem(id: String) throws -> LocalItem? {
        let sql = "SELECT * FROM items WHERE id = ?"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)

            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return readItem(from: stmt)
        }
    }

    public func fetchAllItems(siteID: String) throws -> [LocalItem] {
        let sql = "SELECT * FROM items WHERE site_id = ? ORDER BY is_directory DESC, filename"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, nil)
            return try readItems(from: stmt)
        }
    }

    public func updateItemSyncState(id: String, state: ItemSyncState, localPath: String? = nil) throws {
        var sql = "UPDATE items SET sync_state = '\(state.rawValue)'"
        if let path = localPath {
            sql += ", local_path = '\(path)'"
        }
        sql += " WHERE id = '\(id)'"
        try execute(sql)
    }

    public func deleteItems(courseID: Int, siteID: String) throws {
        try execute("DELETE FROM items WHERE course_id = \(courseID) AND site_id = '\(siteID)'")
    }

    public func deleteAllItems(siteID: String) throws {
        try execute("DELETE FROM items WHERE site_id = '\(siteID)'")
    }

    private func readItems(from stmt: OpaquePointer) throws -> [LocalItem] {
        var items: [LocalItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            items.append(readItem(from: stmt))
        }
        return items
    }

    private func readItem(from stmt: OpaquePointer) -> LocalItem {
        LocalItem(
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
            contentVersion: sqlite3_column_text(stmt, 15).map { String(cString: $0) }
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
            sqlite3_bind_text(stmt, 2, (cursor.siteID as NSString).utf8String, -1, nil)
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
            sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, nil)

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
