import Foundation
import SQLite3
import OSLog
import SharedDomain

/// SQLite database manager for Foodle's local persistence.
public final class Database: @unchecked Sendable {
    private static let appGroupIdentifier = "group.es.amodrono.foodle"
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "es.amodrono.foodle.persistence.db", qos: .userInitiated)
    private let logger = Logger(subsystem: "es.amodrono.foodle.persistence", category: "Database")
    private let path: String
    public var filePath: String { path }

    public static let schemaVersion = 6

    public init(path: String? = nil) throws {
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
        try migrateSchema()
        logger.info("Database opened at \(self.path, privacy: .public)")
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private static func databaseDirectory(in appSupport: URL) -> URL {
        appSupport.appendingPathComponent("Foodle", isDirectory: true)
    }

    private static func databaseURL(in appSupport: URL) -> URL {
        databaseDirectory(in: appSupport).appendingPathComponent("foodle.db")
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
                .appendingPathComponent("foodle.db\(suffix)")
            let destinationURL = preferredDirectory.appendingPathComponent("foodle.db\(suffix)")

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
                tag_data BLOB
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

        try execute("""
            CREATE TABLE IF NOT EXISTS pending_deletions (
                item_id TEXT NOT NULL,
                deleted_at REAL NOT NULL DEFAULT (strftime('%s', 'now'))
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

        try execute("PRAGMA user_version = \(Self.schemaVersion)")
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
            throw FoodleError.databaseError(detail: message)
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
                supports_mobile_api, supports_file_download, moodle_version, moodle_release, site_name,
                login_type, launch_url, wwwroot, httpswwwroot, show_login_form)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
            sqlite3_bind_int(stmt, 10, Int32(site.capabilities.loginType.rawValue))
            if let l = site.capabilities.launchURL { sqlite3_bind_text(stmt, 11, (l as NSString).utf8String, -1, nil) }
            if let w = site.capabilities.wwwroot { sqlite3_bind_text(stmt, 12, (w as NSString).utf8String, -1, nil) }
            if let h = site.capabilities.httpswwwroot { sqlite3_bind_text(stmt, 13, (h as NSString).utf8String, -1, nil) }
            sqlite3_bind_int(stmt, 14, site.capabilities.showLoginForm ? 1 : 0)

            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FoodleError.databaseError(detail: "Failed to save site: \(String(cString: sqlite3_errmsg(db)))")
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
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)

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
        // Use INSERT ... ON CONFLICT to preserve user-set custom_folder_name and subscription_state
        let sql = """
            INSERT INTO courses (id, site_id, short_name, full_name, summary,
                category_id, start_date, end_date, last_accessed, visible, subscription_state, custom_folder_name)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
                custom_folder_name = COALESCE(courses.custom_folder_name, excluded.custom_folder_name)
        """
        try queue.sync {
            try executeUnsafe("BEGIN TRANSACTION")
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
                let subscriptionState = course.isSyncEnabled
                    ? CourseSubscriptionState.discovered.rawValue
                    : CourseSubscriptionState.unsubscribed.rawValue
                sqlite3_bind_text(stmt, 11, (subscriptionState as NSString).utf8String, -1, nil)
                if let cfn = course.customFolderName {
                    sqlite3_bind_text(stmt, 12, (cfn as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 12)
                }

                _ = sqlite3_step(stmt)
            }
            try executeUnsafe("COMMIT")
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
                // Column 10 = subscription_state, Column 11 = custom_folder_name
                let subscriptionState: String = {
                    guard sqlite3_column_type(stmt, 10) != SQLITE_NULL else { return "discovered" }
                    return sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? "discovered"
                }()

                let customFolderName: String? = {
                    let colCount = sqlite3_column_count(stmt)
                    guard colCount > 11, sqlite3_column_type(stmt, 11) != SQLITE_NULL else { return nil }
                    return sqlite3_column_text(stmt, 11).map { String(cString: $0) }
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
                    isSyncEnabled: subscriptionState != CourseSubscriptionState.unsubscribed.rawValue
                ))
            }
            return courses
        }
    }

    public func updateCourseSubscription(courseID: Int, siteID: String, state: CourseSubscriptionState) throws {
        try execute("UPDATE courses SET subscription_state = '\(state.rawValue)' WHERE id = \(courseID) AND site_id = '\(siteID)'")
    }

    public func updateCourseCustomFolderName(courseID: Int, siteID: String, customName: String?) throws {
        let sql = "UPDATE courses SET custom_folder_name = ? WHERE id = ? AND site_id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }

            if let name = customName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_int64(stmt, 2, Int64(courseID))
            sqlite3_bind_text(stmt, 3, (siteID as NSString).utf8String, -1, nil)

            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FoodleError.databaseError(detail: "Failed to update custom folder name")
            }
        }
    }
}

// MARK: - Course Tag Operations

extension Database {
    public func saveCourseTags(_ tags: [FinderTag], courseID: Int, siteID: String) throws {
        try queue.sync {
            try executeUnsafe("BEGIN TRANSACTION")

            // Remove existing tags for this course
            let deleteSQL = "DELETE FROM course_tags WHERE course_id = ? AND site_id = ?"
            let deleteStmt = try prepareStatement(deleteSQL)
            defer { sqlite3_finalize(deleteStmt) }
            sqlite3_bind_int64(deleteStmt, 1, Int64(courseID))
            sqlite3_bind_text(deleteStmt, 2, (siteID as NSString).utf8String, -1, nil)
            _ = sqlite3_step(deleteStmt)

            // Insert new tags
            let insertSQL = "INSERT INTO course_tags (course_id, site_id, tag_name, tag_color) VALUES (?, ?, ?, ?)"
            for tag in tags {
                let stmt = try prepareStatement(insertSQL)
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, Int64(courseID))
                sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (tag.name as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 4, Int32(tag.color.rawValue))
                _ = sqlite3_step(stmt)
            }

            try executeUnsafe("COMMIT")
        }
    }

    public func fetchCourseTags(courseID: Int, siteID: String) throws -> [FinderTag] {
        let sql = "SELECT tag_name, tag_color FROM course_tags WHERE course_id = ? AND site_id = ? ORDER BY tag_name"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(courseID))
            sqlite3_bind_text(stmt, 2, (siteID as NSString).utf8String, -1, nil)

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
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, nil)

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
                modification_date, sync_state, is_pinned, local_path, remote_url, content_version, tag_data)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        try queue.sync {
            try executeUnsafe("BEGIN TRANSACTION")
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
                if let td = item.tagData {
                    sqlite3_bind_blob(stmt, 17, (td as NSData).bytes, Int32(td.count), nil)
                } else {
                    sqlite3_bind_null(stmt, 17)
                }

                _ = sqlite3_step(stmt)
            }
            try executeUnsafe("COMMIT")
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

    public func updateItemFilename(id: String, filename: String) throws {
        let sql = "UPDATE items SET filename = ? WHERE id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (filename as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FoodleError.databaseError(detail: "Failed to update item filename")
            }
        }
    }

    public func updateItemTagData(id: String, tagData: Data?) throws {
        let sql = "UPDATE items SET tag_data = ? WHERE id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            if let td = tagData {
                sqlite3_bind_blob(stmt, 1, (td as NSData).bytes, Int32(td.count), nil)
            } else {
                sqlite3_bind_null(stmt, 1)
            }
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FoodleError.databaseError(detail: "Failed to update item tag data")
            }
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

    public func updateItemPinned(id: String, isPinned: Bool) throws {
        let sql = "UPDATE items SET is_pinned = ? WHERE id = ?"
        try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, isPinned ? 1 : 0)
            sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            let status = sqlite3_step(stmt)
            guard status == SQLITE_DONE else {
                throw FoodleError.databaseError(detail: "Failed to update item pinned state")
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
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, nil)
            return try readItems(from: stmt)
        }
    }

    public func deleteItems(courseID: Int, siteID: String) throws {
        try queue.sync {
            // Clear stale pending deletions from previous cycles before recording new ones.
            try executeUnsafe("DELETE FROM pending_deletions")
            // Record IDs for the File Provider to report as deletions.
            try executeUnsafe("""
                INSERT INTO pending_deletions (item_id)
                SELECT id FROM items WHERE course_id = \(courseID) AND site_id = '\(siteID)'
            """)
            try executeUnsafe("DELETE FROM items WHERE course_id = \(courseID) AND site_id = '\(siteID)'")
        }
    }

    public func deleteAllItems(siteID: String) throws {
        try queue.sync {
            try executeUnsafe("DELETE FROM pending_deletions")
            try executeUnsafe("""
                INSERT INTO pending_deletions (item_id)
                SELECT id FROM items WHERE site_id = '\(siteID)'
            """)
            try executeUnsafe("DELETE FROM items WHERE site_id = '\(siteID)'")
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
        let tagData: Data? = {
            let colCount = sqlite3_column_count(stmt)
            guard colCount > 16, sqlite3_column_type(stmt, 16) != SQLITE_NULL else { return nil }
            let bytes = sqlite3_column_blob(stmt, 16)
            let length = sqlite3_column_bytes(stmt, 16)
            guard let bytes, length > 0 else { return nil }
            return Data(bytes: bytes, count: Int(length))
        }()

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
            tagData: tagData
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

    public func fetchAllSyncCursors(siteID: String) throws -> [SyncCursor] {
        let sql = "SELECT * FROM sync_cursors WHERE site_id = ?"
        return try queue.sync {
            let stmt = try prepareStatement(sql)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (siteID as NSString).utf8String, -1, nil)

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
