// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SwiftUI
import AuthenticationServices
import AppKit
import CoreSpotlight
import UserNotifications
import SharedDomain
import FoodleNetworking
import FoodlePersistence
import FoodleSyncEngine
@preconcurrency import FileProvider
import OSLog

/// The central observable state for the Foodle app.
@MainActor
final class AppState: ObservableObject {
    @Published var currentScreen: AppScreen = .onboarding
    @Published var accounts: [Account] = []
    @Published var sites: [MoodleSite] = []
    @Published var courses: [MoodleCourse] = []
    @Published var courseTags: [Int: [FinderTag]] = [:]
    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published var errorMessage: String?
    /// Set when a sync/load failed because the session is no longer valid.
    /// The workspace surfaces a reconnect prompt rather than a generic error.
    @Published var sessionExpired = false
    /// Fine-grained progress for the in-flight "sync all" pass, shown in the
    /// workspace. Only meaningful while `syncStatus` is `.syncing`.
    @Published var syncProgressDetail: SyncProgressDetail?
    /// Per-course sync state, driving the sidebar status indicators and the
    /// course-detail status pill. Seeded from sync cursors at load and updated
    /// live from the engine during a sync.
    @Published var courseSyncStates: [Int: CourseSubscriptionState] = [:]
    /// Downloaded Moodle cover images, keyed by course id. Populated lazily from
    /// the on-disk cache; the gallery falls back to a generated tile when absent.
    @Published private(set) var courseCoverImages: [Int: NSImage] = [:]

    private let moodleClient = MoodleClient()
    private var database: Database?

    /// On-disk path of the shared database, passed to the bundled MCP helper when
    /// registering it with Claude so it reads the right App Group container.
    var databaseFilePath: String? { database?.filePath }
    private(set) var syncEngine: SyncEngine?
    private(set) var currentToken: AuthToken?
    private(set) var currentSite: MoodleSite?
    private var activeWebAuthSession: WebAuthSession?
    private var isLoadingCourses = false
    private var validatedSitesByURL: [String: MoodleSite] = [:]
    private var automaticSyncTask: Task<Void, Never>?
    private var lastAppliedSyncInterval: Double = -1
    private var sessionBootstrapTask: Task<Void, Error>?
    private var syncSettingsObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "es.amodrono.foodle", category: "AppState")
    private let userDefaults: UserDefaults

    #if DEBUG
    /// When `true`, sign-in completes normally but the token is not persisted,
    /// so the next launch always shows the onboarding flow.
    /// Enable only when you explicitly want ephemeral debug sessions.
    static let skipTokenPersistence = ProcessInfo.processInfo.environment["FOODLE_SKIP_TOKEN_PERSISTENCE"] == "1"
    #endif

    enum AppScreen: Hashable {
        case onboarding
        case workspace
    }

    enum SyncStatus: Equatable {
        case idle
        case syncing(progress: Double)
        case completed
        case error(String)
    }

    /// Per-course progress for a "sync all" pass.
    struct SyncProgressDetail: Equatable {
        var completed: Int
        var total: Int
        var courseName: String
    }

    /// A content + status snapshot for one course, used by the detail overview.
    /// Derived from the local `items` table and the course's sync cursor.
    struct CourseContents: Equatable {
        struct Section: Identifiable, Equatable {
            let id: String
            let name: String
            let fileCount: Int
        }

        var sections: [Section] = []
        var fileCount: Int = 0
        var totalBytes: Int64 = 0
        var downloadedCount: Int = 0
        var lastSynced: Date?

        static let empty = CourseContents()
    }

    private static let syncOnLaunchKey = "syncOnLaunch"
    private static let syncIntervalMinutesKey = "syncIntervalMinutes"
    private static let currentSiteIDKey = "currentSiteID"
    private static let lastKnownAppVersionKey = "lastKnownAppVersion"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        userDefaults.register(defaults: [
            Self.syncOnLaunchKey: true,
            Self.syncIntervalMinutesKey: 30.0
        ])

        do {
            try configureInitialDatabase()
            observeSyncSettings()
            loadAccounts()
        } catch {
            logger.error("Failed to initialize database: \(error.localizedDescription, privacy: .public)")
        }

    }

    private func configureInitialDatabase() throws {
        if let siteID = userDefaults.string(forKey: Self.currentSiteIDKey) {
            database = try openCanonicalDatabase(siteID: siteID)
        } else {
            database = try Database()
        }
    }

    /// Opens the canonical database in the App Group container — the single
    /// source of truth shared by the app, the File Provider extension, and the
    /// MCP helper.
    ///
    /// Earlier builds kept this database inside the File Provider domain's state
    /// directory, which `fileproviderd` deletes on every domain remove/re-add
    /// (Sparkle update, session recovery, manual reset). The app then kept
    /// writing through the now-unlinked handle, surfacing as
    /// "saveItems step failed: disk I/O error". The App Group container is never
    /// reclaimed, so the handle stays valid across domain resets.
    private func openCanonicalDatabase(siteID: String) throws -> Database {
        migrateLegacyStateDirectoryDatabaseIfNeeded(siteID: siteID)
        let database = try Database()
        userDefaults.set(siteID, forKey: Self.currentSiteIDKey)
        return database
    }

    /// One-time migration for users upgrading from a build that stored the
    /// database in the File Provider state directory: copy any surviving per-site
    /// data into the App Group container so courses, items, and sync cursors
    /// carry over. Safe to skip when the legacy database is already gone (e.g. the
    /// domain was reset before this build first ran).
    private func migrateLegacyStateDirectoryDatabaseIfNeeded(siteID: String) {
        let flagKey = "didMigrateStateDirDB.\(siteID)"
        guard !userDefaults.bool(forKey: flagKey) else { return }

        guard #available(macOS 15.0, *) else {
            userDefaults.set(true, forKey: flagKey)
            return
        }

        let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: siteID))
        let domain = NSFileProviderDomain(identifier: domainID, displayName: siteID)
        guard let manager = NSFileProviderManager(for: domain),
              let stateRoot = try? manager.stateDirectoryURL() else { return }

        let legacyURL = stateRoot
            .appendingPathComponent(".FoodleState", isDirectory: true)
            .appendingPathComponent("Foodle", isDirectory: true)
            .appendingPathComponent("foodle.db")

        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            // Nothing to migrate (fresh install, or the state dir was reclaimed).
            userDefaults.set(true, forKey: flagKey)
            return
        }

        let didStart = stateRoot.startAccessingSecurityScopedResource()
        defer { if didStart { stateRoot.stopAccessingSecurityScopedResource() } }

        do {
            let legacy = try Database(path: legacyURL.path)
            guard try legacy.fetchSite(id: siteID) != nil else {
                userDefaults.set(true, forKey: flagKey)
                return
            }
            let container = try Database()
            // Don't clobber newer container data: only migrate when the legacy
            // database holds more items for this site than the container does.
            let containerItems = (try? container.fetchAllItems(siteID: siteID))?.count ?? 0
            let legacyItems = try legacy.fetchAllItems(siteID: siteID).count
            if legacyItems > containerItems {
                try copyData(from: legacy, to: container, siteID: siteID)
                logger.info("Migrated \(legacyItems) item(s) from the legacy state-directory database into the App Group container for site \(siteID, privacy: .public)")
            }
            userDefaults.set(true, forKey: flagKey)
        } catch {
            // Leave the flag unset so a later launch can retry once readable.
            logger.warning("Legacy state-directory database migration skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies one site's rows (site, accounts, courses, items, sync cursors) from
    /// one database to another. Upserts only — never deletes — so it is safe to
    /// run against a populated destination.
    private func copyData(from source: Database, to destination: Database, siteID: String) throws {
        if let site = try source.fetchSite(id: siteID) {
            try destination.saveSite(site)
        }
        for account in try source.fetchAccounts().filter({ $0.siteID == siteID }) {
            try destination.saveAccount(account)
        }
        let courses = try source.fetchCourses(siteID: siteID)
        if !courses.isEmpty {
            try destination.saveCourses(courses)
        }
        let items = try source.fetchAllItems(siteID: siteID)
        if !items.isEmpty {
            try destination.saveItems(items)
        }
        for cursor in try source.fetchAllSyncCursors(siteID: siteID) {
            try destination.saveSyncCursor(cursor)
        }
    }

    // MARK: - Account Management

    func loadAccounts() {
        guard let db = database else { return }
        do {
            accounts = try db.fetchAccounts()

            // Try the most recent account first (last in the list), since older
            // accounts may have had their keychain tokens cleared by logout.
            for account in accounts.reversed() {
                guard account.state.isConnected else { continue }
                guard let site = try db.fetchSite(id: account.siteID) else { continue }
                guard let tokenString = try KeychainManager.shared.retrieveToken(forAccount: account.id) else { continue }

                activateAuthenticatedSession(
                    site: site,
                    token: AuthToken(token: tokenString),
                    accounts: [account],
                    database: db,
                    triggerLaunchSync: true
                )
                return
            }
        } catch {
            logger.error("Failed to load accounts: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Onboarding

    func validateSite(urlString: String) async throws -> MoodleSite {
        try await validateSite(urlString: urlString) { _ in }
    }

    func validateSite(
        urlString: String,
        onProgress: @escaping @MainActor (SiteValidationProgress) -> Void
    ) async throws -> MoodleSite {
        guard let normalizedURL = normalizedValidationURL(from: urlString) else {
            throw FoodleError.siteUnreachable(url: URL(string: "https://invalid")!)
        }

        let cacheKey = normalizedURL.absoluteString
        if let cachedSite = validatedSitesByURL[cacheKey] {
            return cachedSite
        }

        let site = try await moodleClient.validateSite(url: normalizedURL) { progress in
            await onProgress(progress)
        }

        validatedSitesByURL[cacheKey] = site
        validatedSitesByURL[site.baseURL.absoluteString] = site
        return site
    }

    private func normalizedValidationURL(from urlString: String) -> URL? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate) else { return nil }

        var normalizedString = url.absoluteString
        while normalizedString.hasSuffix("/") {
            normalizedString.removeLast()
        }

        return URL(string: normalizedString)
    }

    /// Sign in with username/password (for sites that support direct login).
    func signIn(site: MoodleSite, username: String, password: String) async throws {
        let token = try await moodleClient.authenticate(site: site, username: username, password: password)
        try await completeSignIn(site: site, token: token)
    }

    /// Sign in with username/password, persisting credentials without
    /// activating the session. Used during onboarding.
    func signInAndPersist(site: MoodleSite, username: String, password: String) async throws {
        let token = try await moodleClient.authenticate(site: site, username: username, password: password)
        try await persistSignIn(site: site, token: token)
    }

    /// Sign in via browser SSO using ASWebAuthenticationSession.
    /// Used for `SiteLoginType.browser`.
    func signInWithBrowserSSO(
        site: MoodleSite,
        presentationContext: ASWebAuthenticationPresentationContextProviding
    ) async throws {
        let webAuth = WebAuthSession()
        activeWebAuthSession = webAuth
        defer { activeWebAuthSession = nil }

        let result = try await webAuth.authenticate(site: site, presentationContext: presentationContext)
        try await completeSignIn(site: site, token: result.token)
    }

    /// Sign in via browser SSO, persisting credentials without activating the
    /// session. Used during onboarding.
    func signInWithBrowserSSOAndPersist(
        site: MoodleSite,
        presentationContext: ASWebAuthenticationPresentationContextProviding
    ) async throws {
        let webAuth = WebAuthSession()
        activeWebAuthSession = webAuth
        defer { activeWebAuthSession = nil }

        let result = try await webAuth.authenticate(site: site, presentationContext: presentationContext)
        try await persistSignIn(site: site, token: result.token)
    }

    /// Shared post-authentication setup: fetch user info, persist, configure File Provider.
    func completeSignIn(site: MoodleSite, token: AuthToken) async throws {
        try await persistSignIn(site: site, token: token)
        guard let db = database else { return }
        activateAuthenticatedSession(
            site: site,
            token: token,
            accounts: accounts,
            database: db,
            triggerLaunchSync: true
        )
    }

    /// Persist credentials and set up File Provider without activating the session
    /// or switching screens. Used during onboarding so the Airlock flow can
    /// continue through its remaining steps before transitioning to the workspace.
    func persistSignIn(site: MoodleSite, token: AuthToken) async throws {
        let user = try await moodleClient.fetchUserInfo(site: site, token: token)

        guard let db = database else { throw FoodleError.databaseError(detail: "Database not available") }
        try db.saveSite(site)

        let account = Account(
            siteID: site.id,
            userID: user.id,
            state: .authenticated(userID: user.id)
        )
        try db.saveAccount(account)
        accounts = [account]
        sites = [site]

        #if DEBUG
        if Self.skipTokenPersistence {
            logger.info("DEBUG: Skipping token persistence (skipTokenPersistence is enabled)")
        } else {
            try KeychainManager.shared.storeToken(token.token, forAccount: account.id)
        }
        #else
        try KeychainManager.shared.storeToken(token.token, forAccount: account.id)
        #endif
        // File Provider setup is best-effort: it may fail in unsigned builds,
        // on first install before pluginkit discovers the extension, or if the
        // provisioning profile lacks the File Provider capability.  Sign-in
        // should still succeed so the user can access courses in the app.
        do {
            try await setupFileProviderDomain(site: site)
            database = try openCanonicalDatabase(siteID: site.id)
            await resolveFileProviderAuthentication(for: site)
            await pinToFinderSidebar(site: site)
        } catch {
            logger.warning("File Provider setup skipped: \(error.localizedDescription, privacy: .public)")
        }

        // Store site/token for later activation without switching screens
        currentSite = site
        currentToken = token
    }

    /// Activate the sync engine and load courses without changing screens.
    /// Called during onboarding's setup step so the Airlock flow can finish
    /// before the workspace appears.
    func activateAfterOnboarding() {
        guard let site = currentSite, currentToken != nil, let db = database else { return }
        syncEngine = SyncEngine(provider: moodleClient, database: db)

        do {
            courses = try db.fetchCourses(siteID: site.id)
            reloadCourseTags()
        } catch {
            logger.error("Failed to load cached courses: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - File Provider Domain

    /// Full domain setup used during fresh sign-in: removes stale domains, then adds the new one.
    private func setupFileProviderDomain(site: MoodleSite) async throws {
        await removeAllFileProviderDomains()
        try await addFileProviderDomain(site: site)
    }

    /// Lightweight domain registration used on app relaunch: adds the domain if missing,
    /// without removing existing domains (avoids racing with fileproviderd).
    private func ensureFileProviderDomain(site: MoodleSite) async {
        // Always re-enable — the extension may have been disabled by macOS after
        // a Sparkle update or other bundle change.
        reenableFileProviderExtension()

        do {
            try await addFileProviderDomain(site: site)
        } catch {
            logger.error("File Provider domain setup failed on relaunch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns `true` when the running app version differs from the last recorded
    /// launch, indicating that a Sparkle (or manual) update took place.
    /// Also records the current version so subsequent launches return `false`.
    private func appVersionChanged() -> Bool {
        let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let lastVersion = userDefaults.string(forKey: Self.lastKnownAppVersionKey)
        userDefaults.set(currentVersion, forKey: Self.lastKnownAppVersionKey)
        guard let lastVersion else { return false } // first launch ever
        return lastVersion != currentVersion
    }

    /// After an app update (e.g. via Sparkle) the embedded File Provider extension
    /// binary changes.  macOS disables the extension via `pluginkit` and
    /// `NSFileProviderManager.add` does NOT re-enable it.  The only reliable fix
    /// is to call `pluginkit -e use` to re-enable the extension, then re-seed the
    /// shared database so the extension has up-to-date state.
    private func reregisterFileProviderDomain(site: MoodleSite) async {
        logger.info("App version changed — re-registering File Provider domain for \(site.displayName, privacy: .public)")

        // Re-enable the extension — macOS disables it when Sparkle replaces the bundle.
        reenableFileProviderExtension()

        // 1. Re-store the keychain token under the current signing context.
        //    This ensures the File Provider extension (which may have a refreshed
        //    code signature after Sparkle replaced the bundle) can read the token.
        if let token = currentToken,
           let account = accounts.first(where: { $0.state.isConnected }) {
            do {
                try KeychainManager.shared.storeToken(token.token, forAccount: account.id)
                logger.info("Re-stored keychain token for post-update access")
            } catch {
                logger.error("Failed to re-store keychain token: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 2. Remove and re-add the domain to force macOS to reload the extension.
        //    The canonical database lives in the App Group container, so it
        //    survives the domain removal — no snapshot or re-seed is needed, and
        //    the live `database`/`syncEngine` handles stay valid.
        let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id))
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)

        do {
            try await NSFileProviderManager.remove(domain)
            logger.info("Removed File Provider domain for re-registration")
        } catch {
            logger.error("Failed to remove domain during re-registration: \(error.localizedDescription, privacy: .public)")
        }

        do {
            try await addFileProviderDomain(site: site)
        } catch {
            logger.error("Failed to re-add domain during re-registration: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Re-enable the File Provider extension via `pluginkit`.
    ///
    /// macOS disables the extension when Sparkle replaces the app bundle.
    /// `NSFileProviderManager.add(domain)` does NOT re-enable it — only
    /// `pluginkit -e use` does.
    private func reenableFileProviderExtension() {
        let extensionBundleID = BundleIdentifiers.prefix + ".file-provider"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-e", "use", "-i", extensionBundleID]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                logger.info("Re-enabled File Provider extension via pluginkit")
            } else {
                logger.warning("pluginkit exited with status \(process.terminationStatus)")
            }
        } catch {
            logger.error("Failed to run pluginkit: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func addFileProviderDomain(site: MoodleSite) async throws {
        let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id))
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
        domain.isHidden = false

        do {
            try await NSFileProviderManager.add(domain)
            logger.info("File Provider domain added: \(site.displayName, privacy: .public)")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
            logger.info("File Provider domain already exists: \(site.displayName, privacy: .public)")
        } catch let error as NSError {
            logger.error("Failed to add File Provider domain: \(error.localizedDescription, privacy: .public) [\(error.domain, privacy: .public):\(error.code)]")
            let detail = "\(error.localizedDescription) (\(error.domain):\(error.code))"
            throw FoodleError.domainSetupFailed(detail: detail)
        }
    }

    private func removeAllFileProviderDomains() async {
        do {
            let domainPairs = try await Self.fileProviderDomainPairs()
            for pair in domainPairs {
                let domain = NSFileProviderDomain(
                    identifier: NSFileProviderDomainIdentifier(pair.id),
                    displayName: pair.name
                )
                do {
                    try await NSFileProviderManager.remove(domain)
                    logger.info("Removed stale File Provider domain: \(pair.id, privacy: .public)")
                } catch {
                    logger.warning("Failed to remove domain \(pair.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            logger.warning("Could not enumerate existing File Provider domains: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Course Management

    func loadCourses() async {
        guard let site = currentSite, let token = currentToken else { return }
        guard let account = accounts.first else { return }
        guard !isLoadingCourses else { return }

        isLoadingCourses = true
        defer { isLoadingCourses = false }

        do {
            let remoteCourses = try await moodleClient.fetchCourses(
                site: site,
                token: token,
                userID: account.userID ?? 0
            )
            try database?.saveCourses(remoteCourses)
            // Re-read from database to pick up persisted custom folder names
            courses = try database?.fetchCourses(siteID: site.id) ?? remoteCourses
            reloadCourseTags()
            seedCourseSyncStatesFromCursors(siteID: site.id)
            loadCourseCovers()
            logger.info("Loaded \(self.courses.count) courses")
        } catch let error as FoodleError where error.requiresReauthentication {
            logger.error("Failed to load courses: session expired")
            handleSessionExpired()
        } catch {
            logger.error("Failed to load courses: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Course Covers

    /// On-disk cache directory for downloaded course cover images.
    private var coverCacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CourseCovers", isDirectory: true)
    }

    /// Populate `courseCoverImages` from the cache, downloading any missing cover
    /// for courses that expose a Moodle overview image. Courses without an image
    /// are skipped — the gallery shows a generated tile for them.
    private func loadCourseCovers() {
        guard let token = currentToken else { return }
        for course in courses {
            guard let remoteURL = course.imageURL, courseCoverImages[course.id] == nil else { continue }

            // Key the cache file by site too, so a colliding course id across
            // two Moodle sites can't serve the wrong site's cover.
            let destination = coverCacheDirectory.appendingPathComponent("\(course.siteID)-\(course.id)")
            if let cached = NSImage(contentsOf: destination) {
                courseCoverImages[course.id] = cached
                continue
            }

            Task { await downloadCover(courseID: course.id, from: remoteURL, token: token, to: destination) }
        }
    }

    private func downloadCover(courseID: Int, from remoteURL: URL, token: AuthToken, to destination: URL) async {
        do {
            try await moodleClient.downloadFile(url: remoteURL, token: token, destination: destination)
            if let image = NSImage(contentsOf: destination) {
                courseCoverImages[courseID] = image
            } else {
                // The download wasn't a valid image (e.g. an HTML error body):
                // drop it so a stale bad file doesn't linger and the next launch
                // can re-attempt cleanly.
                try? FileManager.default.removeItem(at: destination)
            }
        } catch {
            logger.debug("Course cover download failed for \(courseID): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Mark courses that already have a sync cursor as `.synced` so the sidebar
    /// reflects prior syncs after a relaunch, before any live engine state.
    private func seedCourseSyncStatesFromCursors(siteID: String) {
        guard let database else { return }
        let cursors = (try? database.fetchAllSyncCursors(siteID: siteID)) ?? []
        for cursor in cursors where courseSyncStates[cursor.courseID] == nil {
            courseSyncStates[cursor.courseID] = .synced
        }
    }

    func reloadCourseTags() {
        guard let db = database, let site = currentSite else { return }
        courseTags = (try? db.fetchAllCourseTags(siteID: site.id)) ?? [:]
    }

    /// Import Finder tags that users may have applied directly on course
    /// folders in `~/Library/CloudStorage`.  Tags already tracked in the
    /// database are left untouched; only newly-discovered tags are added.
    func importFinderTagsFromDisk() async {
        guard let site = currentSite, let db = database else { return }
        guard let rootURL = await fileProviderRootURL(for: site) else { return }

        for course in courses where course.isSyncEnabled {
            let folderURL = rootURL.appendingPathComponent(course.effectiveFolderName, isDirectory: true)
            guard let diskTags = Self.readFinderTags(at: folderURL), !diskTags.isEmpty else { continue }

            let existingTags = (try? db.fetchCourseTags(courseID: course.id, siteID: course.siteID)) ?? []
            let existingNames = Set(existingTags.map(\.name))
            let newTags = diskTags.filter { !existingNames.contains($0.name) }
            guard !newTags.isEmpty else { continue }

            let merged = existingTags + newTags
            updateCourseTags(for: course, tags: merged)
        }
    }

    /// Read Finder tags from a file/directory URL by parsing the
    /// `com.apple.metadata:_kMDItemUserTags` resource value.
    private static func readFinderTags(at url: URL) -> [FinderTag]? {
        guard let values = try? url.resourceValues(forKeys: [.tagNamesKey]),
              let names = values.tagNames, !names.isEmpty else { return nil }

        return names.compactMap { raw -> FinderTag? in
            // macOS stores tags as "Name\nColorIndex" or just "Name"
            let parts = raw.split(separator: "\n", maxSplits: 1)
            let name = String(parts[0])
            let colorIndex = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let color = FinderTag.Color(rawValue: colorIndex) ?? .none
            return FinderTag(name: name, color: color)
        }
    }

    // MARK: - Course Customization

    func updateCustomFolderName(for course: MoodleCourse, name: String?) {
        guard let db = database, let site = currentSite else { return }
        do {
            try db.updateCourseCustomFolderName(courseID: course.id, siteID: course.siteID, customName: name)
            if let index = courses.firstIndex(where: { $0.id == course.id && $0.siteID == course.siteID }) {
                courses[index].customFolderName = name
            }

            // Update the course root item in the items table so the File Provider sees it
            let courseItemID = "course-\(site.id)-\(course.id)"
            var updatedCourse = course
            updatedCourse.customFolderName = name
            try db.updateItemFilename(id: courseItemID, filename: updatedCourse.effectiveFolderName)
            signalFileProviderChanges()
        } catch {
            logger.error("Failed to update custom folder name: \(error.localizedDescription, privacy: .public)")
        }
    }

    func updateCourseCustomIcon(for course: MoodleCourse, iconName: String?) {
        guard let db = database else { return }
        do {
            try db.updateCourseCustomIconName(courseID: course.id, siteID: course.siteID, iconName: iconName)
            if let index = courses.firstIndex(where: { $0.id == course.id && $0.siteID == course.siteID }) {
                courses[index].customIconName = iconName
            }
        } catch {
            logger.error("Failed to update custom icon: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setCourseSyncEnabled(_ enabled: Bool, for course: MoodleCourse) {
        guard let db = database, let site = currentSite else { return }
        let newState: CourseSubscriptionState = enabled ? .discovered : .unsubscribed
        do {
            try db.updateCourseSubscription(courseID: course.id, siteID: course.siteID, state: newState)
            if let index = courses.firstIndex(where: { $0.id == course.id && $0.siteID == course.siteID }) {
                courses[index].isSyncEnabled = enabled
            }

            // Remove items from the File Provider and Spotlight when disabling sync
            if !enabled {
                try db.deleteItems(courseID: course.id, siteID: site.id)
                SpotlightIndexer.shared.removeItems(forCourse: course.id, siteID: course.siteID)
                signalFileProviderChanges()
            }
        } catch {
            logger.error("Failed to update course sync state: \(error.localizedDescription, privacy: .public)")
        }
    }

    func fetchCourseTags(for course: MoodleCourse) -> [FinderTag] {
        guard let db = database else { return [] }
        return (try? db.fetchCourseTags(courseID: course.id, siteID: course.siteID)) ?? []
    }

    /// Group `courses` by their Finder tags for the sidebar and gallery. Returns
    /// one entry per tag in use (sorted by name), then a trailing `nil`-tag entry
    /// for untagged courses. Empty when no tags exist anywhere.
    func tagSections(for courses: [MoodleCourse]) -> [(tag: FinderTag?, courses: [MoodleCourse])] {
        let allTags = courseTags

        var usedTags: [FinderTag] = []
        var seen = Set<String>()
        for tags in allTags.values {
            for tag in tags where !seen.contains(tag.name) {
                usedTags.append(tag)
                seen.insert(tag.name)
            }
        }
        usedTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard !usedTags.isEmpty else { return [] }

        var sections: [(tag: FinderTag?, courses: [MoodleCourse])] = []
        for tag in usedTags {
            let matching = courses.filter { course in
                allTags[course.id]?.contains(where: { $0.name == tag.name }) ?? false
            }
            if !matching.isEmpty {
                sections.append((tag: tag, courses: matching))
            }
        }

        let untagged = courses.filter { allTags[$0.id]?.isEmpty ?? true }
        if !untagged.isEmpty {
            sections.append((tag: nil, courses: untagged))
        }

        return sections
    }

    /// Build a content + status snapshot for `course` from the local database:
    /// file count, total size, downloaded count, last-synced time, and the
    /// top-level sections with the number of files each contains.
    func courseContents(for course: MoodleCourse) -> CourseContents {
        guard let db = database else { return .empty }
        guard let items = try? db.fetchItems(courseID: course.id, siteID: course.siteID),
              !items.isEmpty else {
            // No items yet, but a cursor may still record a prior sync time.
            let lastSynced = (try? db.fetchSyncCursor(courseID: course.id, siteID: course.siteID))?.lastSyncDate
            return CourseContents(lastSynced: lastSynced)
        }

        let files = items.filter { !$0.isDirectory }
        let fileCount = files.count
        let totalBytes = files.reduce(Int64(0)) { $0 + $1.fileSize }
        let downloadedCount = files.filter { $0.syncState == .materialized }.count

        // Children grouped by parent, so we can count files anywhere beneath a
        // section (modules may nest files inside folders).
        let childrenByParent = Dictionary(grouping: items, by: { $0.parentID })
        func descendantFileCount(under id: String) -> Int {
            var total = 0
            for child in childrenByParent[id] ?? [] {
                if child.isDirectory {
                    total += descendantFileCount(under: child.id)
                } else {
                    total += 1
                }
            }
            return total
        }

        let courseRootID = "course-\(course.siteID)-\(course.id)"
        let sections = (childrenByParent[courseRootID] ?? [])
            .filter { $0.isDirectory }
            .map { CourseContents.Section(id: $0.id, name: $0.filename, fileCount: descendantFileCount(under: $0.id)) }

        let lastSynced = (try? db.fetchSyncCursor(courseID: course.id, siteID: course.siteID))?.lastSyncDate

        return CourseContents(
            sections: sections,
            fileCount: fileCount,
            totalBytes: totalBytes,
            downloadedCount: downloadedCount,
            lastSynced: lastSynced
        )
    }

    func updateCourseTags(for course: MoodleCourse, tags: [FinderTag]) {
        guard let db = database, let site = currentSite else { return }
        do {
            try db.saveCourseTags(tags, courseID: course.id, siteID: course.siteID)
            courseTags[course.id] = tags.isEmpty ? nil : tags

            // Update the course root item's tag data so the File Provider sees it
            let courseItemID = "course-\(site.id)-\(course.id)"
            let tagData = FinderTag.tagData(from: tags)
            try db.updateItemTagData(id: courseItemID, tagData: tagData)
            signalFileProviderChanges()
        } catch {
            logger.error("Failed to update course tags: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Sync

    func syncAll() async {
        guard let site = currentSite, let token = currentToken, let engine = syncEngine else { return }

        errorMessage = nil
        syncStatus = .syncing(progress: 0)

        let enabledCourses = courses.filter(\.isSyncEnabled)
        syncProgressDetail = enabledCourses.isEmpty
            ? nil
            : SyncProgressDetail(completed: 0, total: enabledCourses.count, courseName: enabledCourses[0].shortName)
        for course in enabledCourses {
            courseSyncStates[course.id] = .syncing
        }

        // Poll the engine for per-course progress while the sync runs so the
        // workspace can show "syncing X of Y".
        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let progress = await engine.allProgress()
                for (id, courseProgress) in progress {
                    self.courseSyncStates[id] = courseProgress.state
                }
                let completed = enabledCourses.filter { (progress[$0.id]?.state ?? .syncing) != .syncing }.count
                let current = enabledCourses.first { (progress[$0.id]?.state ?? .syncing) == .syncing }
                self.syncProgressDetail = SyncProgressDetail(
                    completed: completed,
                    total: enabledCourses.count,
                    courseName: current?.shortName ?? ""
                )
                self.syncStatus = .syncing(
                    progress: enabledCourses.isEmpty ? 1 : Double(completed) / Double(enabledCourses.count)
                )
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { syncProgressDetail = nil }

        do {
            try await engine.syncAllCourses(site: site, token: token, courses: enabledCourses)
            progressTask.cancel()
            let finalProgress = await engine.allProgress()
            for course in enabledCourses {
                courseSyncStates[course.id] = finalProgress[course.id]?.state ?? .synced
            }
            syncStatus = .completed
            lastSyncDate = Date()
            signalFileProviderChanges()
            indexForSpotlight()
            notifySyncCompletedIfEnabled(courseCount: enabledCourses.count)
            // Refresh deadlines/grades/quizzes in the background so it doesn't
            // delay the content sync's completion. Best-effort.
            Task { await refreshTracking() }
        } catch let error as FoodleError where error.requiresReauthentication {
            progressTask.cancel()
            handleSessionExpired()
        } catch is CancellationError {
            progressTask.cancel()
            syncStatus = .idle
        } catch {
            progressTask.cancel()
            for course in enabledCourses where courseSyncStates[course.id] == .syncing {
                courseSyncStates[course.id] = .error
            }
            syncStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func syncCourse(_ course: MoodleCourse) async {
        guard let site = currentSite, let token = currentToken, let engine = syncEngine else { return }

        errorMessage = nil
        syncStatus = .syncing(progress: 0)
        courseSyncStates[course.id] = .syncing

        do {
            try await engine.syncCourse(site: site, token: token, course: course)
            courseSyncStates[course.id] = .synced
            syncStatus = .completed
            lastSyncDate = Date()
            signalFileProviderChanges()
        } catch let error as FoodleError where error.requiresReauthentication {
            handleSessionExpired()
        } catch is CancellationError {
            courseSyncStates[course.id] = .stale
            syncStatus = .idle
        } catch {
            courseSyncStates[course.id] = .error
            syncStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Coursework Tracking

    /// Fetch read-only coursework tracking (assignments + submission status,
    /// grades, quizzes + attempts) for the sync-enabled courses and store it for
    /// the MCP server. Best-effort, but a *failed* list fetch is never persisted
    /// as an empty result — the replace-all saves would otherwise wipe good data
    /// on a transient network/token error. Independent per-item calls run with
    /// bounded concurrency instead of one-at-a-time.
    func refreshTracking() async {
        guard let site = currentSite, let token = currentToken, let db = database,
              let userID = accounts.first?.userID else { return }
        let courseIDs = courses.filter(\.isSyncEnabled).map(\.id)
        guard !courseIDs.isEmpty else { return }
        let client = moodleClient

        // Assignments (+ submission status). Persist only if the list fetch worked.
        if let base = try? await client.fetchAssignments(site: site, token: token, courseIDs: courseIDs) {
            let enriched = await Self.boundedMap(base) { assignment in
                var a = assignment
                if let status = try? await client.fetchSubmissionStatus(site: site, token: token, assignmentID: assignment.id) {
                    a.submitted = status.submitted
                    a.graded = status.graded
                    a.grade = status.grade
                }
                return a
            }
            try? db.saveAssignments(enriched, siteID: site.id)
        }

        // Grades, per course. Skip the save entirely if every course fetch failed.
        let gradeResults = await Self.boundedMap(courseIDs) { courseID -> [MoodleGradeItem]? in
            try? await client.fetchGrades(site: site, token: token, courseID: courseID, userID: userID)
        }
        if gradeResults.contains(where: { $0 != nil }) {
            try? db.saveGradeItems(gradeResults.compactMap { $0 }.flatMap { $0 }, siteID: site.id)
        }

        // Quizzes (+ attempts). Persist only if the quiz-list fetch worked.
        if let quizzes = try? await client.fetchQuizzes(site: site, token: token, courseIDs: courseIDs) {
            try? db.saveQuizzes(quizzes, siteID: site.id)

            let attemptResults = await Self.boundedMap(quizzes) { quiz -> [MoodleQuizAttempt]? in
                try? await client.fetchQuizAttempts(site: site, token: token, quizID: quiz.id, userID: userID)
            }
            if attemptResults.contains(where: { $0 != nil }) {
                try? db.saveQuizAttempts(attemptResults.compactMap { $0 }.flatMap { $0 }, siteID: site.id)
            }
        }

        logger.info("Tracking refresh complete")
    }

    /// Run `transform` over `items` with a bounded number of concurrent tasks.
    private static func boundedMap<T: Sendable, R: Sendable>(
        _ items: [T],
        maxConcurrency: Int = 5,
        _ transform: @escaping @Sendable (T) async -> R
    ) async -> [R] {
        guard !items.isEmpty else { return [] }
        return await withTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            for _ in 0..<min(maxConcurrency, items.count) {
                let index = next
                next += 1
                group.addTask { (index, await transform(items[index])) }
            }
            while let (index, value) = await group.next() {
                results[index] = value
                if next < items.count {
                    let index = next
                    next += 1
                    group.addTask { (index, await transform(items[index])) }
                }
            }
            return results.compactMap { $0 }
        }
    }

    // MARK: - Session Recovery

    /// Called when a sync or load fails because the session is no longer valid.
    /// Surfaces a reconnect prompt and stops the automatic sync loop so we don't
    /// keep hammering the server with a dead token.
    private func handleSessionExpired() {
        logger.warning("Session expired — prompting user to reconnect")
        sessionExpired = true
        syncStatus = .error(FoodleError.tokenExpired.localizedDescription)
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        lastAppliedSyncInterval = -1
    }

    /// Sign out and return to onboarding so the user can authenticate again.
    func reconnect() async {
        sessionExpired = false
        await logout()
    }

    /// Clear a surfaced error banner.
    func dismissError() {
        errorMessage = nil
        if case .error = syncStatus {
            syncStatus = lastSyncDate == nil ? .idle : .completed
        }
    }

    // MARK: - Notifications

    private func notifySyncCompletedIfEnabled(courseCount: Int) {
        guard userDefaults.bool(forKey: "notifyOnSyncComplete") else { return }

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            var authorized = settings.authorizationStatus == .authorized
            if settings.authorizationStatus == .notDetermined {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized else { return }

            let content = UNMutableNotificationContent()
            content.title = "Sync complete"
            content.body = courseCount == 1
                ? "1 course is up to date."
                : "\(courseCount) courses are up to date."
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try? await center.add(request)
        }
    }

    private func signalFileProviderChanges() {
        guard let site = currentSite else { return }
        signalFileProviderChanges(for: site)
    }

    private func signalFileProviderChanges(for site: MoodleSite) {
        let domainID = BundleIdentifiers.fileProviderDomainID(siteID: site.id)
        let displayName = site.displayName
        let logger = self.logger
        Task.detached {
            await Self.performSignalEnumerators(
                domainID: domainID, displayName: displayName, logger: logger
            )
        }
    }

    /// Called when the app becomes active (e.g. when the user clicks "Sign In" in Finder).
    /// If already authenticated, re-signals auth resolution to the File Provider.
    func resolveFileProviderAuthIfNeeded() {
        guard currentScreen == .workspace,
              let site = currentSite,
              currentToken != nil else { return }

        Task {
            await resolveFileProviderAuthentication(for: site, maxAttempts: 2)
        }
    }

    private func resolveFileProviderAuthentication(for site: MoodleSite, maxAttempts: Int = 5) async {
        let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id))
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)

        for attempt in 1...maxAttempts {
            guard let manager = NSFileProviderManager(for: domain) else {
                logger.warning("No NSFileProviderManager for domain \(domainID.rawValue, privacy: .public) while resolving authentication (attempt \(attempt))")
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                return
            }

            let authError = NSFileProviderError(.notAuthenticated)
            let signalError = await Self.signalResolvedFileProviderError(
                using: manager,
                authError: authError
            )

            if let signalError = signalError as? NSError {
                logger.warning("Failed to resolve File Provider authentication (attempt \(attempt)): \(signalError.localizedDescription, privacy: .public) [\(signalError.domain, privacy: .public):\(signalError.code)]")
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
            } else {
                logger.info("Resolved File Provider authentication state for \(site.displayName, privacy: .public)")
                break
            }
        }

        signalFileProviderChanges(for: site)
    }

    // MARK: - Logout

    func logout() async {
        guard let account = accounts.first else { return }

        // Cancel all background work before touching shared resources
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        sessionBootstrapTask?.cancel()
        sessionBootstrapTask = nil
        syncEngine = nil

        // Remove File Provider domain
        if let site = currentSite {
            let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id))
            let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
            try? await NSFileProviderManager.remove(domain)
        }

        // Clear Spotlight index
        SpotlightIndexer.shared.removeAllItems()

        // Clear Keychain
        try? KeychainManager.shared.deleteToken(forAccount: account.id)

        // Clear the canonical database in the App Group container, then reopen a
        // fresh empty handle for the onboarding screen.
        try? database?.deleteAllData()
        database = nil
        database = try? Database()
        userDefaults.removeObject(forKey: Self.currentSiteIDKey)

        // Reset state
        accounts = []
        sites = []
        courses = []
        courseTags = [:]
        // Clear per-course caches keyed by course id so they can't leak across
        // a sign-out/site-switch where a course id collides with the next site.
        courseSyncStates = [:]
        courseCoverImages = [:]
        validatedSitesByURL.removeAll()
        currentSite = nil
        currentToken = nil
        lastSyncDate = nil
        syncStatus = .idle
        currentScreen = .onboarding
    }

    // MARK: - Diagnostics

    func rebuildIndex() async {
        try? database?.rebuildIndex()
        await syncAll()
    }

    func openFileProviderInFinder(selecting course: MoodleCourse? = nil) async {
        guard let site = currentSite else { return }

        guard let rootURL = await fileProviderRootURL(for: site) else {
            logger.warning("Cannot open in Finder: File Provider root URL not available")
            return
        }

        let targetURL: URL
        if let course {
            let courseURL = rootURL.appendingPathComponent(course.effectiveFolderName, isDirectory: true)
            targetURL = FileManager.default.fileExists(atPath: courseURL.path) ? courseURL : rootURL
        } else {
            targetURL = rootURL
        }

        // NSWorkspace.shared.open() can be blocked by the sandbox for File
        // Provider CloudStorage URLs after binary changes (e.g. Sparkle updates).
        // Shell out to /usr/bin/open which is not subject to the app sandbox.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [targetURL.path]
        try? process.run()
    }

    func resetProvider() async {
        guard let site = currentSite else { return }

        reenableFileProviderExtension()

        // Re-store the keychain token to guarantee accessibility after reset.
        if let token = currentToken,
           let account = accounts.first(where: { $0.state.isConnected }) {
            do {
                try KeychainManager.shared.storeToken(token.token, forAccount: account.id)
            } catch {
                logger.error("Failed to re-store keychain token during reset: \(error.localizedDescription, privacy: .public)")
            }
        }

        let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id))
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)

        do {
            try await NSFileProviderManager.remove(domain)
        } catch {
            logger.error("Failed to remove domain during reset: \(error.localizedDescription, privacy: .public)")
        }

        do {
            try await setupFileProviderDomain(site: site)
        } catch {
            logger.error("Failed to re-add domain during reset: \(error.localizedDescription, privacy: .public)")
        }

        // The canonical database in the App Group container is untouched by the
        // domain reset; just rebuild the in-memory session handles so they point
        // at it again.
        if let token = currentToken {
            do {
                let database = try openCanonicalDatabase(siteID: site.id)
                self.database = database
                currentSite = site
                currentToken = token
                sites = [site]
                syncEngine = SyncEngine(provider: moodleClient, database: database)
                courses = try database.fetchCourses(siteID: site.id)
                reloadCourseTags()
            } catch {
                logger.error("Failed to reopen database after reset: \(error.localizedDescription, privacy: .public)")
            }
        }

        await resolveFileProviderAuthentication(for: site)
    }

    func reauthenticate() async {
        await logout()
    }

    private func activateAuthenticatedSession(
        site: MoodleSite,
        token: AuthToken,
        accounts: [Account],
        database: Database,
        triggerLaunchSync: Bool
    ) {
        let activeDatabase: Database
        do {
            let canonical = try openCanonicalDatabase(siteID: site.id)
            activeDatabase = canonical
            self.database = canonical
        } catch {
            logger.error("Failed to adopt canonical database: \(error.localizedDescription, privacy: .public)")
            activeDatabase = database
        }

        currentSite = site
        currentToken = token
        self.accounts = accounts
        sites = [site]
        syncEngine = SyncEngine(provider: moodleClient, database: activeDatabase)
        currentScreen = .workspace

        do {
            courses = try activeDatabase.fetchCourses(siteID: site.id)
            reloadCourseTags()
        } catch {
            logger.error("Failed to load cached courses: \(error.localizedDescription, privacy: .public)")
        }

        sessionBootstrapTask = Task { [weak self] in
            guard let self else { return }

            if self.appVersionChanged() {
                await self.reregisterFileProviderDomain(site: site)
            } else {
                await self.ensureFileProviderDomain(site: site)
            }

            // Clear any downloads left mid-flight by a previous run so they
            // don't appear stuck in-progress.
            try? self.database?.resetStaleDownloads(siteID: site.id)

            try Task.checkCancellation()
            await self.resolveFileProviderAuthentication(for: site)
            try Task.checkCancellation()
            await self.loadCourses()
            try Task.checkCancellation()
            await self.importFinderTagsFromDisk()
            try Task.checkCancellation()
            if triggerLaunchSync && self.userDefaults.bool(forKey: Self.syncOnLaunchKey) {
                await self.syncAll()
            }
            try Task.checkCancellation()
            self.refreshAutomaticSyncSchedule()
        }
    }

    private func observeSyncSettings() {
        // UserDefaults.didChangeNotification fires on every defaults write
        // across the app (launch counters, prompt state, etc.), so check
        // whether the value we actually care about changed before tearing
        // down and recreating the sync task.
        syncSettingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let currentInterval = self.userDefaults.double(forKey: Self.syncIntervalMinutesKey)
                guard currentInterval != self.lastAppliedSyncInterval else { return }
                self.refreshAutomaticSyncSchedule()
            }
        }
    }

    private func refreshAutomaticSyncSchedule() {
        automaticSyncTask?.cancel()
        automaticSyncTask = nil

        guard currentSite != nil, currentToken != nil, syncEngine != nil else {
            lastAppliedSyncInterval = -1
            return
        }

        let rawInterval = userDefaults.double(forKey: Self.syncIntervalMinutesKey)
        // Clamp to a sane positive range so a corrupt or maliciously edited
        // preference can't overflow UInt64 in the nanosecond conversion.
        let intervalMinutes = max(0, min(rawInterval, 24 * 60))
        lastAppliedSyncInterval = intervalMinutes
        guard intervalMinutes > 0 else { return }

        let intervalNanoseconds = UInt64(intervalMinutes * 60 * 1_000_000_000)
        automaticSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    break
                }

                guard let self else { return }
                await self.syncAll()
            }
        }
    }

    private func fileProviderRootURL(for site: MoodleSite) async -> URL? {
        let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id))
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
        guard let manager = NSFileProviderManager(for: domain) else { return nil }

        let result = await Self.userVisibleFileProviderURL(using: manager, for: .rootContainer)
        if let error = result.error {
            logger.warning("Failed to resolve File Provider root URL: \(error.localizedDescription, privacy: .public)")
        }
        return result.url
    }

    // Use the async bridge of getDomainsWithCompletionHandler so the result
    // is delivered back on MainActor.  The original completion-handler version
    // accessed NSFileProviderDomain properties on the XPC callback queue,
    // which crashes on macOS 26+ where those properties are MainActor-isolated.
    private static func fileProviderDomainPairs() async throws -> [(id: String, name: String)] {
        let domains = try await NSFileProviderManager.domains()
        return domains.map { (id: $0.identifier.rawValue, name: $0.displayName) }
    }

    // MARK: - File Provider Helpers (nonisolated)

    // FileProvider delivers completion-handler callbacks on background queues
    // (e.g. FPM-SignalUpdateQueue). If these helpers were @MainActor-isolated
    // (the default for methods on this class), Swift 6's runtime would trap
    // when the callback fires off the main thread.
    //
    // Marking them `nonisolated` ensures the continuation carries no actor
    // expectation, so the callback queue is irrelevant.
    //
    // DO NOT remove `nonisolated` — doing so reintroduces a release-only crash.

    private nonisolated static func performSignalEnumerators(
        domainID: String,
        displayName: String,
        logger: Logger
    ) async {
        let fpDomainID = NSFileProviderDomainIdentifier(domainID)
        let domain = NSFileProviderDomain(identifier: fpDomainID, displayName: displayName)

        guard let manager = NSFileProviderManager(for: domain) else {
            logger.warning("No NSFileProviderManager for domain \(domainID, privacy: .public) — domain may not be registered")
            return
        }

        for identifier: NSFileProviderItemIdentifier in [.workingSet, .rootContainer] {
            do {
                try await manager.signalEnumerator(for: identifier)
            } catch let error as NSError where error.domain == NSFileProviderErrorDomain && error.code == -2001 {
                logger.info("File Provider not ready yet, will retry signal in 3s")
                try? await Task.sleep(for: .seconds(3))
                do {
                    try await manager.signalEnumerator(for: identifier)
                } catch {
                    logger.warning("File Provider signal retry failed: \(error.localizedDescription, privacy: .public)")
                }
            } catch {
                logger.error("Failed to signal File Provider: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private nonisolated static func signalResolvedFileProviderError(
        using manager: NSFileProviderManager,
        authError: NSFileProviderError
    ) async -> Error? {
        await withCheckedContinuation { continuation in
            manager.signalErrorResolved(authError) { error in
                continuation.resume(returning: error)
            }
        }
    }

    private nonisolated static func userVisibleFileProviderURL(
        using manager: NSFileProviderManager,
        for identifier: NSFileProviderItemIdentifier
    ) async -> (url: URL?, error: Error?) {
        await withCheckedContinuation { continuation in
            manager.getUserVisibleURL(for: identifier) { url, error in
                continuation.resume(returning: (url, error))
            }
        }
    }

    // MARK: - Spotlight

    func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        let prefix = BundleIdentifiers.spotlightPrefix + "."

        if identifier.hasPrefix("\(prefix)course.") {
            let components = identifier.dropFirst("\(prefix)course.".count).split(separator: ".")
            if let courseIDStr = components.last,
               let courseID = Int(courseIDStr),
               let course = courses.first(where: { $0.id == courseID }) {
                Task { await openFileProviderInFinder(selecting: course) }
            }
        } else if identifier.hasPrefix("\(prefix)item.") {
            let itemID = String(identifier.dropFirst("\(prefix)item.".count))
            if let db = database, let item = try? db.fetchItem(id: itemID),
               let course = courses.first(where: { $0.id == item.courseID }) {
                Task { await openFileProviderInFinder(selecting: course) }
            }
        }
    }

    private func indexForSpotlight() {
        guard let db = database, let site = currentSite else { return }
        let allItems = (try? db.fetchAllItems(siteID: site.id)) ?? []
        let siteName = site.capabilities.siteName ?? site.displayName
        SpotlightIndexer.shared.indexCourses(courses, items: allItems, siteName: siteName)
    }

    // MARK: - Finder Sidebar Favorites

    /// Adds the File Provider root to Finder's sidebar Favorites using sfltool.
    /// This is best-effort — the tool may not be available or may fail silently.
    private func pinToFinderSidebar(site: MoodleSite) async {
        guard let rootURL = await fileProviderRootURL(for: site) else {
            logger.info("Cannot pin to sidebar: File Provider root URL not available yet")
            return
        }

        // Run sfltool off the main actor to avoid blocking the UI.
        let sidebarURL = rootURL.absoluteString
        let log = logger
        Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
            process.arguments = [
                "add-item",
                "com.apple.LSSharedFileList.FavoriteItems",
                sidebarURL
            ]

            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    log.info("Pinned Findle to Finder sidebar Favorites")
                } else {
                    log.warning("sfltool exited with status \(process.terminationStatus)")
                }
            } catch {
                log.warning("Could not pin to Finder sidebar: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
