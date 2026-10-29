// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import Combine
import AuthenticationServices
import AppKit
import CoreSpotlight
import UserNotifications
import SharedDomain
import FindleNetworking
import FindlePersistence
import FindleSyncEngine
@preconcurrency import FileProvider
import OSLog

/// Outcome of placing the Documents shortcut to the personal files folder.
enum DocumentsShortcutResult: Sendable {
    /// The alias was written at this URL.
    case created(URL)
    /// Something already occupies the alias path, so nothing was written.
    case alreadyExists(URL)
    /// The alias could not be written. The message is the underlying error.
    case failed(String)
}

/// The central observable state for the Findle app.
@MainActor
final class AppState: ObservableObject {
    @Published var currentScreen: AppScreen = .onboarding
    @Published var accounts: [Account] = []
    @Published var sites: [MoodleSite] = []
    @Published var courses: [MoodleCourse] = []
    @Published var courseTags: [Int: [FinderTag]] = [:]
    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published private(set) var lastSyncReport: SyncRunReport?
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
    private var databaseSecurityScopedURL: URL?

    /// On-disk path of the shared database, passed to the bundled MCP helper when
    /// registering it with Claude so it reads the right App Group container.
    var databaseFilePath: String? { database?.filePath }
    /// Keep bootstrap and adopted-store diagnostics available across a provider transition.
    private(set) var diagnosticDatabasePaths: Set<String> = []
    private(set) var databaseInitializationFailure: DiagnosticFailure?
    private var incompatibleDatabaseError: UnsupportedDatabaseSchemaError?
    private(set) var syncEngine: SyncEngine?
    private(set) var currentToken: AuthToken?
    private(set) var currentSite: MoodleSite?
    private var activeWebAuthSession: WebAuthSession?
    private var loadingCoursesID: UUID?
    private var courseLoadTask: Task<Void, Never>?
    private var authenticationSetupTask: Task<Void, Error>?
    private var authenticationRequestTask: Task<(AuthToken, MoodleUser), Error>?
    private var subscriptionTasks: [Int: Task<Void, Never>] = [:]
    private var subscriptionRevisions: [Int: UUID] = [:]
    private var courseSyncTasks: [UUID: Task<Bool, Never>] = [:]
    private var keychainRestoreTask: Task<Void, Never>?
    private var requestedSyncTask: Task<Void, Never>?
    private var validatedSitesByURL: [String: MoodleSite] = [:]
    private var automaticSyncTask: Task<Void, Never>?
    private var lastAppliedSyncInterval: Double = -1
    private var sessionBootstrapTask: Task<Void, Error>?
    /// The "sync all" pass currently running, if any. Concurrent callers await it.
    private var syncAllTask: Task<Void, Never>?
    private var trackingRefreshTask: Task<Void, Never>?
    /// The user's own files. Kept in a plain folder outside the File Provider, so they
    /// survive unsyncing a course, signing out, and deleting the app.
    private let personalFileStore = PersonalFileStore(rootURL: PersonalFileStore.defaultRootURL())
    /// The most recent personal files reconcile. Each new run waits for it, so runs never overlap.
    private var personalFilesReconcileTask: Task<Void, Never>?
    /// Watches the personal files folder while a session is active, so edits made in Finder
    /// or directly in the folder reach Finder without waiting for the next sync.
    private var personalFilesWatcher: PersonalFilesWatcher?
    /// Cover downloads in flight, keyed by course id, so a reload doesn't start a second one.
    private var coverDownloadsInFlight: Set<Int> = []
    private var coverTasks: [Int: Task<Void, Never>] = [:]
    private let sessionWork = SessionWorkCoordinator()
    private var isDatabaseTransitioning: Bool {
        incompatibleDatabaseError != nil || sessionWork.isTransitioning || sessionWork.isAdoptingDatabase
    }
    private var syncSettingsObserver: NSObjectProtocol?
    private var syncNowObserver: DarwinNotification.Token?
    /// Guards against a burst of "Sync Now" requests (the extension posts twice
    /// when it has to cold-launch the app) turning into overlapping syncs.
    private var lastSyncNowRequest: Date?
    private let logger = Logger(subsystem: "es.amodrono.findle", category: "AppState")
    private let userDefaults: UserDefaults

    #if DEBUG
    /// When `true`, sign-in completes normally but the token is not persisted,
    /// so the next launch always shows the onboarding flow.
    /// Enable only when you explicitly want ephemeral debug sessions.
    static let skipTokenPersistence = ProcessInfo.processInfo.environment["FINDLE_SKIP_TOKEN_PERSISTENCE"] == "1"
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
    /// The File Provider extension cannot fetch on its own — it only reads rows
    /// this app writes — so this interval is the upper bound on how stale Finder
    /// can be. Keep it short enough that new coursework shows up on its own, and
    /// pair it with the "Sync Now" Finder action for an immediate refresh.
    static let defaultSyncIntervalMinutes = 5.0
    private static let currentSiteIDKey = "currentSiteID"
    private static let lastKnownAppVersionKey = "lastKnownAppVersion"
    private static let personalFilesShortcutAttemptedKey = "personalFilesShortcutAttempted"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        userDefaults.register(defaults: [
            Self.syncOnLaunchKey: true,
            Self.syncIntervalMinutesKey: Self.defaultSyncIntervalMinutes
        ])
        EmbeddedAuthCoordinator.resumePendingCleanup()

        do {
            try configureInitialDatabase()
            observeSyncSettings()
            observeSyncNowRequests()
            loadAccounts()
        } catch {
            if let incompatible = error as? UnsupportedDatabaseSchemaError { rejectIncompatibleDatabase(incompatible) }
            databaseInitializationFailure = DiagnosticFailure(error)
            logger.error("Failed to initialize database: \(DiagnosticFailure(error).summary, privacy: .public)")
        }

    }

    private struct SharedDatabaseLocation {
        let securityScopedDirectoryURL: URL
        let databaseURL: URL
    }

    #if DEBUG
    /// Isolated, in-memory data for native layout checks. Never opens user storage.
    static func interfacePreview() throws -> AppState {
        let database = try Database(path: ":memory:")
        let preview = AppState(previewDatabase: database)
        let site = MoodleSite(id: "preview", displayName: "University", baseURL: URL(string: "https://moodle.example.edu")!)
        let course = MoodleCourse(id: 1, shortName: "OS", fullName: "Operating Systems", siteID: site.id)
        let courses = [course,
            MoodleCourse(id: 2, shortName: "SD", fullName: "Digital Systems", siteID: site.id),
            MoodleCourse(id: 3, shortName: "CALC", fullName: "Calculus", siteID: site.id, isSyncEnabled: false)]
        try database.saveSite(site)
        try database.saveCourses(courses)
        try database.saveSyncCursor(SyncCursor(courseID: 1, siteID: site.id, lastSyncDate: Date().addingTimeInterval(-180)))
        try database.saveCourseOutline(CourseOutlineSnapshot(courseID: 1, sections: [
            CourseOutlineSection(id: 10, name: "Introduction", sectionNumber: 0, modules: [
                CourseOutlineModule(id: 100, name: "Course guide", type: "resource")]),
            CourseOutlineSection(id: 11, name: "Processes", sectionNumber: 1, modules: [
                CourseOutlineModule(id: 101, name: "Lecture notes", type: "resource"),
                CourseOutlineModule(id: 102, name: "Lab exercises", type: "folder")]),
            CourseOutlineSection(id: 12, name: "Scheduling", sectionNumber: 2, modules: [
                CourseOutlineModule(id: 103, name: "Scheduling.pdf", type: "resource"),
                CourseOutlineModule(id: 104, name: "Practice questions", type: "quiz")])
        ]), siteID: site.id)
        try database.saveItems([
            LocalItem(id: "guide", siteID: site.id, courseID: 1, remoteID: 100, filename: "Course guide.pdf"),
            LocalItem(id: "lecture", siteID: site.id, courseID: 1, remoteID: 101, filename: "Processes.pdf"),
            LocalItem(id: "scheduling", siteID: site.id, courseID: 1, remoteID: 103, filename: "Scheduling.pdf")])
        preview.currentSite = site
        preview.sites = [site]
        preview.courses = courses
        preview.currentScreen = .workspace
        return preview
    }

    private init(previewDatabase: Database) {
        userDefaults = UserDefaults(suiteName: "es.amodrono.findle.interface-preview")!
        database = previewDatabase
    }
    #endif

    private func configureInitialDatabase() throws {
        // Always open the App Group bootstrap database first, so the app has a
        // working handle even when the File Provider domain isn't usable yet.
        // Right after a Sparkle update macOS temporarily disables the extension,
        // so `stateDirectoryURL()` (inside openSharedDatabase) throws on the first
        // launch. Without this fallback that throw propagated out of init, left
        // `database` nil, and blocked sign-in with "Database not available".
        var bootstrapDatabase = try Database()
        // Before the AppKit migration, an unusable App Group put the bootstrap
        // database inside the host's sandbox container. Keep that existing
        // database accessible rather than making its account disappear.
        if (try bootstrapDatabase.fetchAccounts()).isEmpty, let bundleID = Bundle.main.bundleIdentifier {
            let legacy = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Application Support/Findle/findle.db")
            if legacy.path != bootstrapDatabase.filePath,
               FileManager.default.fileExists(atPath: legacy.path),
               let existing = try? Database(path: legacy.path),
               let accounts = try? existing.fetchAccounts(), !accounts.isEmpty {
                bootstrapDatabase = existing
            }
        }
        database = bootstrapDatabase
        diagnosticDatabasePaths.insert(bootstrapDatabase.filePath)

        guard let siteID = userDefaults.string(forKey: Self.currentSiteIDKey) else { return }

        // Upgrade to the shared File Provider state database when it's reachable.
        // If it isn't (e.g. the extension is disabled post-update), keep the
        // bootstrap handle — the session bootstrap re-seeds and adopts the shared
        // database once the extension is back.
        do {
            if let sharedDatabase = try openSharedDatabase(siteID: siteID, seedFrom: bootstrapDatabase) {
                database = sharedDatabase
            }
        } catch let error as UnsupportedDatabaseSchemaError {
            throw error
        } catch {
            logger.warning("Shared database is unavailable at startup: \(DiagnosticFailure(error).summary, privacy: .public)")
        }
    }

    private func openSharedDatabase(siteID: String, seedFrom sourceDatabase: Database?) throws -> Database? {
        if let incompatibleDatabaseError { throw incompatibleDatabaseError }
        do {
            return try openCompatibleSharedDatabase(siteID: siteID, seedFrom: sourceDatabase)
        } catch let error as UnsupportedDatabaseSchemaError {
            rejectIncompatibleDatabase(error)
            throw error
        }
    }

    private func rejectIncompatibleDatabase(_ error: UnsupportedDatabaseSchemaError) {
        incompatibleDatabaseError = error
        databaseInitializationFailure = DiagnosticFailure(error)
        errorMessage = error.localizedDescription
        syncStatus = .error(error.localizedDescription)
        automaticSyncTask?.cancel()
        trackingRefreshTask?.cancel()
        courseLoadTask?.cancel()
        stopPersonalFilesWatcher()
        // An unavailable provider may use bootstrap temporarily; a newer schema
        // must never be treated as that recoverable condition.
        database = nil
        syncEngine = nil
    }

    private func openCompatibleSharedDatabase(siteID: String, seedFrom sourceDatabase: Database?) throws -> Database? {
        guard let location = try sharedDatabaseLocation(siteID: siteID) else { return nil }

        let didStartAccessing = location.securityScopedDirectoryURL.startAccessingSecurityScopedResource()
        var adoptedScope = false
        defer {
            if didStartAccessing && !adoptedScope {
                location.securityScopedDirectoryURL.stopAccessingSecurityScopedResource()
            }
        }

        if try sharedDatabaseNeedsSeeding(siteID: siteID, databaseURL: location.databaseURL) {
            guard let sourceDatabase else { return nil }
            try seedSharedDatabase(from: sourceDatabase, siteID: siteID, destinationURL: location.databaseURL)
        }

        let sharedDatabase = try Database(path: location.databaseURL.path)
        databaseSecurityScopedURL?.stopAccessingSecurityScopedResource()
        databaseSecurityScopedURL = didStartAccessing ? location.securityScopedDirectoryURL : nil
        adoptedScope = true
        userDefaults.set(siteID, forKey: Self.currentSiteIDKey)
        return sharedDatabase
    }

    /// fileproviderd can take a few seconds to expose a new state directory.
    /// Keep the app on its bootstrap database only until that window is
    /// exhausted, rather than starting a sync against a database Finder cannot
    /// see.
    private func adoptSharedDatabaseWithRetry(siteID: String, seedFrom sourceDatabase: Database?) async -> Database? {
        guard !sessionWork.isAdoptingDatabase else { return nil }
        let lease = sessionWork.lease
        let adoption = sessionWork.beginAdoption()
        defer {
            sessionWork.endAdoption(adoption)
            if sessionWork.isCurrent(lease), !isDatabaseTransitioning {
                startPersonalFilesWatcher()
                refreshAutomaticSyncSchedule()
            }
        }

        // Bootstrap owns this call, so drain only its producers, never the
        // bootstrap task itself. No writer may remain on the previous handle
        // while the destination is seeded and the app adopts its replacement.
        stopPersonalFilesWatcher()
        let automatic = automaticSyncTask
        let syncing = syncAllTask
        let tracking = trackingRefreshTask
        let loading = courseLoadTask
        let personal = personalFilesReconcileTask
        let courseSyncs = Array(courseSyncTasks.values)
        automatic?.cancel()
        syncing?.cancel()
        tracking?.cancel()
        loading?.cancel()
        personal?.cancel()
        courseSyncs.forEach { $0.cancel() }
        automaticSyncTask = nil
        syncAllTask = nil
        trackingRefreshTask = nil
        courseLoadTask = nil
        loadingCoursesID = nil
        personalFilesReconcileTask = nil
        courseSyncTasks.removeAll()
        await syncEngine?.stopAllSyncs()
        await automatic?.value
        await syncing?.value
        await tracking?.value
        await loading?.value
        await personal?.value
        for task in courseSyncs { _ = await task.value }
        guard sessionWork.isCurrent(lease) else { return nil }
        syncProgressDetail = nil
        if case .syncing = syncStatus { syncStatus = .idle }
        for id in courseSyncStates.keys where courseSyncStates[id] == .syncing { courseSyncStates[id] = .stale }

        for attempt in 1...5 {
            do {
                try Task.checkCancellation()
                guard sessionWork.isCurrent(lease) else { return nil }
                if let sharedDatabase = try openSharedDatabase(siteID: siteID, seedFrom: sourceDatabase) {
                    return sharedDatabase
                }
            } catch is CancellationError {
                return nil
            } catch is UnsupportedDatabaseSchemaError {
                return nil
            } catch {
                logger.warning("Shared database adoption attempt \(attempt) failed: \(DiagnosticFailure(error).summary, privacy: .public)")
            }

            guard attempt < 5 else { break }
            do {
                try await Task.sleep(for: .seconds(TimeInterval(attempt)))
            } catch {
                return nil
            }
        }
        return nil
    }

    private func sharedDatabaseLocation(siteID: String) throws -> SharedDatabaseLocation? {
        let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: siteID))
        let domain = NSFileProviderDomain(identifier: domainID, displayName: siteID)
        guard let manager = NSFileProviderManager(for: domain) else { return nil }

        guard #available(macOS 15.0, *) else { return nil }
        let storageRootURL = try manager.stateDirectoryURL()

        let databaseURL = storageRootURL
            .appendingPathComponent(".FindleState", isDirectory: true)
            .appendingPathComponent("Findle", isDirectory: true)
            .appendingPathComponent("findle.db")

        return SharedDatabaseLocation(
            securityScopedDirectoryURL: storageRootURL,
            databaseURL: databaseURL
        )
    }

    private func sharedDatabaseNeedsSeeding(siteID: String, databaseURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return true }

        let sharedDatabase = try Database(path: databaseURL.path)
        guard try sharedDatabase.isSeedComplete() else { return true }
        let hasSite = try sharedDatabase.fetchSite(id: siteID) != nil
        let hasConnectedAccount = try sharedDatabase.fetchAccounts().contains {
            $0.siteID == siteID && $0.state.isConnected
        }

        return !(hasSite && hasConnectedAccount)
    }

    private func seedSharedDatabase(from sourceDatabase: Database, siteID: String, destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try Database(path: destinationURL.path)
        let sourcePath = URL(fileURLWithPath: sourceDatabase.filePath).standardizedFileURL.path
        let destinationPath = destinationURL.standardizedFileURL.path
        let source: Database
        if sourcePath == destinationPath {
            if try destination.isSeedComplete(),
               try destination.fetchSite(id: siteID) != nil,
               try destination.fetchAccounts().contains(where: { $0.siteID == siteID && $0.state.isConnected }) {
                try destination.verifyCompleteRecoveryState()
                return
            }
            let bootstrap = try Database()
            guard URL(fileURLWithPath: bootstrap.filePath).standardizedFileURL.path != destinationPath else {
                throw FindleError.databaseError(detail: "A separate recovery database is required before restoring Finder.")
            }
            source = bootstrap
        } else {
            source = sourceDatabase
        }
        guard try source.fetchSite(id: siteID) != nil,
              try source.fetchAccounts().contains(where: { $0.siteID == siteID && $0.state.isConnected }) else {
            throw FindleError.databaseError(detail: "The recovery database does not contain the connected account.")
        }
        let recovery = personalFileStore.rootURL.appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent("index-\(UUID().uuidString).db")
        try source.writeRecoverySnapshot(to: recovery)
        try destination.restoreRecoverySnapshot(from: recovery, resetRemoteContent: true)
        logger.info("Restored the complete File Provider database")
    }

    // MARK: - Account Management

    func loadAccounts() {
        guard !sessionWork.isTransitioning else { return }
        guard let db = database else { return }
        do {
            accounts = try db.fetchAccounts()
        } catch {
            logger.error("Failed to load accounts: \(DiagnosticFailure(error).summary, privacy: .public)")
            return
        }

        if restoreMostRecentSession(from: accounts, database: db) == .keychainErrorsOnly {
            // Keychain reads can fail transiently right after launch. Retry once
            // before falling back to onboarding.
            logger.info("Every connected account failed a keychain read; retrying once")
            let lease = sessionWork.lease
            keychainRestoreTask?.cancel()
            keychainRestoreTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.sessionWork.isCurrent(lease), self.database === db,
                      self.currentSite == nil else { return }
                _ = self.restoreMostRecentSession(from: self.accounts, database: db)
            }
        }
    }

    private enum SessionRestoreResult {
        case restored
        case keychainErrorsOnly
        case noSession
    }

    /// Activate the most recent connected account that has a usable token. A
    /// failure on one account is logged and the next account is tried, so a single
    /// bad keychain item cannot hide the others.
    private func restoreMostRecentSession(from accounts: [Account], database db: Database) -> SessionRestoreResult {
        // Try the most recent account first (last in the list), since older
        // accounts may have had their keychain tokens cleared by logout.
        var connectedCount = 0
        var keychainErrorCount = 0

        for account in accounts.reversed() {
            guard account.state.isConnected else { continue }
            connectedCount += 1

            do {
                guard let site = try db.fetchSite(id: account.siteID) else { continue }
                // A missing token is "not found", not an error, so it doesn't count toward the retry.
                guard let tokenString = try KeychainManager.shared.retrieveToken(forAccount: account.id) else { continue }

                activateAuthenticatedSession(
                    site: site,
                    token: AuthToken(token: tokenString),
                    accounts: [account],
                    database: db,
                    triggerLaunchSync: true
                )
                return .restored
            } catch let error as KeychainError {
                keychainErrorCount += 1
                logger.error("Keychain read failed for account \(account.id, privacy: .private): \(DiagnosticFailure(error).summary, privacy: .public)")
            } catch {
                logger.error("Failed to restore account \(account.id, privacy: .private): \(DiagnosticFailure(error).summary, privacy: .public)")
            }
        }

        return connectedCount > 0 && keychainErrorCount == connectedCount ? .keychainErrorsOnly : .noSession
    }

    // MARK: - Onboarding

    func validateSite(urlString: String) async throws -> MoodleSite {
        try await validateSite(urlString: urlString) { _ in }
    }

    func validateSite(
        urlString: String,
        onProgress: @escaping @MainActor (SiteValidationProgress) -> Void
    ) async throws -> MoodleSite {
        try Task.checkCancellation()
        guard !sessionWork.isTransitioning else { throw CancellationError() }
        let lease = sessionWork.lease
        guard let normalizedURL = normalizedValidationURL(from: urlString) else {
            throw FindleError.siteUnreachable(url: URL(string: "https://invalid")!)
        }

        let cacheKey = normalizedURL.absoluteString
        if let cachedSite = validatedSitesByURL[cacheKey] {
            return cachedSite
        }

        let discovered = try await moodleClient.validateSite(url: normalizedURL) { progress in
            await MainActor.run {
                guard self.sessionWork.isCurrent(lease) else { return }
                onProgress(progress)
            }
        }
        guard sessionWork.isCurrent(lease) else { throw CancellationError() }
        let site = try preservingSiteIdentity(discovered)

        validatedSitesByURL[cacheKey] = site
        validatedSitesByURL[site.baseURL.absoluteString] = site
        return site
    }

    private func preservingSiteIdentity(_ site: MoodleSite) throws -> MoodleSite {
        var knownSites = currentSite.map { [$0] } ?? []
        knownSites += sites
        if let database {
            for account in try database.fetchAccounts() {
                if let persisted = try database.fetchSite(id: account.siteID) { knownSites.append(persisted) }
            }
        }
        return site.preservingIdentity(from: knownSites)
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
        try await authenticateAndPersist(site: site, activate: true) {
            try await self.moodleClient.authenticate(site: site, username: username, password: password)
        }
    }

    func signInAndPersist(site: MoodleSite, username: String, password: String) async throws {
        try await authenticateAndPersist(site: site, activate: false) {
            try await self.moodleClient.authenticate(site: site, username: username, password: password)
        }
    }

    /// Own an embedded authentication request before its UI begins waiting for
    /// the callback, so logout cancels it and retires its persistence lease.
    func signInAndPersist(
        site: MoodleSite,
        tokenProvider: @escaping @MainActor () async throws -> AuthToken
    ) async throws {
        try await authenticateAndPersist(site: site, activate: false, tokenProvider: tokenProvider)
    }

    func signInWithBrowserSSO(
        site: MoodleSite,
        presentationContext: ASWebAuthenticationPresentationContextProviding
    ) async throws {
        try await authenticateAndPersist(site: site, activate: true) {
            try await self.browserToken(site: site, presentationContext: presentationContext)
        }
    }

    func signInWithBrowserSSOAndPersist(
        site: MoodleSite,
        presentationContext: ASWebAuthenticationPresentationContextProviding
    ) async throws {
        try await authenticateAndPersist(site: site, activate: false) {
            try await self.browserToken(site: site, presentationContext: presentationContext)
        }
    }

    private func browserToken(
        site: MoodleSite,
        presentationContext: ASWebAuthenticationPresentationContextProviding
    ) async throws -> AuthToken {
        let webAuth = WebAuthSession()
        activeWebAuthSession = webAuth
        defer {
            if activeWebAuthSession === webAuth { activeWebAuthSession = nil }
        }
        return try await webAuth.authenticate(site: site, presentationContext: presentationContext).token
    }

    func completeSignIn(site: MoodleSite, token: AuthToken) async throws {
        try await authenticateAndPersist(site: site, activate: true) { token }
    }

    /// Onboarding persists the identity while retaining control of its screen.
    func persistSignIn(site: MoodleSite, token: AuthToken) async throws {
        try await authenticateAndPersist(site: site, activate: false) { token }
    }

    private func authenticateAndPersist(
        site: MoodleSite,
        activate: Bool,
        tokenProvider: @escaping @MainActor () async throws -> AuthToken
    ) async throws {
        if let incompatibleDatabaseError { throw incompatibleDatabaseError }
        let attempt = try sessionWork.beginAuthentication()
        activeWebAuthSession?.cancel()
        authenticationRequestTask?.cancel()
        defer { sessionWork.finishAuthentication(attempt) }
        let request = Task {
            guard sessionWork.isCurrent(attempt) else { throw CancellationError() }
            let token = try await tokenProvider()
            guard sessionWork.isCurrent(attempt) else { throw CancellationError() }
            let user = try await moodleClient.fetchUserInfo(site: site, token: token)
            return (token, user)
        }
        authenticationRequestTask = request
        defer {
            if sessionWork.isCurrent(attempt) { authenticationRequestTask = nil }
        }
        let authenticated = try await sessionWork.authenticate(attempt: attempt) {
            let response = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: { request.cancel() }
            guard sessionWork.isCurrent(attempt) else { throw CancellationError() }
            // Remove the finished request before its own persistence drain.
            authenticationRequestTask = nil
            return response
        } beginPersistence: {
            await beginSessionTransition(preservingAuthentication: attempt)
        } endPersistence: {
            endSessionTransition()
        } persist: { token, user in
            let site = try preservingSiteIdentity(site)
            let db = try persistAuthenticatedIdentity(site: site, token: token, userID: user.id)
            syncEngine = nil
            return (site, token, db)
        }
        let lease = authenticated.lease
        let (site, token, db) = authenticated.identity

        let setup = Task<Void, Error> {
            // Release exclusive storage ownership before calling providers. Logout
            // can invalidate this attempt immediately, but still drains submitted
            // provider calls before removing the domain; stalled XPC can delay it.
            do {
                guard sessionWork.isCurrent(lease), sessionWork.isCurrent(attempt) else { throw CancellationError() }
                await ensureFileProviderDomain(site: site)
                guard sessionWork.isCurrent(lease), sessionWork.isCurrent(attempt) else { throw CancellationError() }
                if let shared = await adoptSharedDatabaseWithRetry(siteID: site.id, seedFrom: db) {
                    guard sessionWork.isCurrent(lease), sessionWork.isCurrent(attempt) else { throw CancellationError() }
                    database = shared
                }
                if let incompatibleDatabaseError { throw incompatibleDatabaseError }
                guard sessionWork.isCurrent(lease), sessionWork.isCurrent(attempt) else { throw CancellationError() }
                await resolveFileProviderAuthentication(for: site)
                guard sessionWork.isCurrent(lease), sessionWork.isCurrent(attempt) else { throw CancellationError() }
                await pinToFinderSidebar(site: site)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as UnsupportedDatabaseSchemaError {
                throw error
            } catch {
                logger.warning("File Provider setup skipped: \(DiagnosticFailure(error).summary, privacy: .public)")
            }
            guard sessionWork.isCurrent(lease), sessionWork.isCurrent(attempt) else { throw CancellationError() }
            await reconcilePersonalFiles()
            guard sessionWork.isCurrent(lease), sessionWork.isCurrent(attempt) else { throw CancellationError() }
            if activate, let database {
                activateAuthenticatedSession(site: site, token: token, accounts: accounts,
                                             database: database, triggerLaunchSync: true)
            }
        }
        authenticationSetupTask = setup
        defer {
            if sessionWork.isCurrent(attempt) { authenticationSetupTask = nil }
        }
        try await withTaskCancellationHandler {
            try await setup.value
        } onCancel: { setup.cancel() }
    }

    /// All identity and credential writes happen without suspension, after the
    /// previous session has drained and while the transition is still exclusive.
    private func persistAuthenticatedIdentity(site: MoodleSite, token: AuthToken, userID: Int) throws -> Database {
        if try refreshExistingSession(site: site, token: token, userID: userID), let database { return database }
        let db = try database ?? Database()
        let account = Account(siteID: site.id, userID: userID, state: .authenticated(userID: userID))
        #if DEBUG
        if !Self.skipTokenPersistence { try KeychainManager.shared.storeToken(token.token, forAccount: account.id) }
        #else
        try KeychainManager.shared.storeToken(token.token, forAccount: account.id)
        #endif
        try db.saveSite(site)
        try db.saveAccount(account)
        try db.setSeedComplete(true)
        database = db
        accounts = [account]
        sites = [site]
        currentSite = site
        currentToken = token
        courseCoverImages.removeAll()
        clearExpiredSessionAfterSignIn()
        return db
    }

    /// Re-authenticate in place when the site's File Provider database already
    /// belongs to this user. Returns `false` when there is nothing to keep, so the
    /// caller falls through to the full sign-in setup.
    private func refreshExistingSession(site: MoodleSite, token: AuthToken, userID: Int) throws -> Bool {
        let existingDatabase: Database
        let previous: Account
        if let database, let stored = try database.fetchAccounts().last {
            existingDatabase = database
            previous = stored
        } else {
            // An inaccessible existing account must never fall through to fresh setup.
            guard accounts.isEmpty, currentSite == nil else { throw AccountReconnectError.storageUnavailable }
            guard let persistedSiteID = userDefaults.string(forKey: Self.currentSiteIDKey) else { return false }
            guard persistedSiteID == site.id else { throw AccountReconnectError.storageUnavailable }
            let shared: Database?
            do {
                shared = try openSharedDatabase(siteID: site.id, seedFrom: nil)
            } catch let error as UnsupportedDatabaseSchemaError {
                throw error
            } catch {
                throw AccountReconnectError.storageUnavailable
            }
            guard let shared, let stored = try shared.fetchAccounts().last else {
                throw AccountReconnectError.storageUnavailable
            }
            existingDatabase = shared
            previous = stored
        }

        // Preserve the id, creation date, last sync, and all related records.
        let account = try previous.reauthenticated(siteID: site.id, userID: userID)

        #if DEBUG
        if Self.skipTokenPersistence {
            logger.info("DEBUG: Skipping token persistence (skipTokenPersistence is enabled)")
        } else {
            try KeychainManager.shared.storeToken(token.token, forAccount: account.id)
        }
        #else
        try KeychainManager.shared.storeToken(token.token, forAccount: account.id)
        #endif

        try existingDatabase.saveSite(site)
        try existingDatabase.saveAccount(account)
        database = existingDatabase
        accounts = [account]
        sites = [site]

        currentSite = site
        currentToken = token
        clearExpiredSessionAfterSignIn()
        logger.info("Re-authenticated \(site.id, privacy: .private) without rebuilding the File Provider domain")
        return true
    }

    private func clearExpiredSessionAfterSignIn() {
        if sessionExpired {
            syncStatus = .idle
            errorMessage = nil
        }
        sessionExpired = false
    }

    /// Activate the sync engine and load courses without changing screens.
    /// Called during onboarding's setup step so the Airlock flow can finish
    /// before the workspace appears.
    func activateAfterOnboarding() {
        guard !isDatabaseTransitioning else { return }
        guard let site = currentSite, currentToken != nil, let db = database else { return }
        if syncEngine == nil { syncEngine = SyncEngine(provider: moodleClient, database: db) }

        do {
            courses = try db.fetchCourses(siteID: site.id)
            reloadCourseTags()
        } catch {
            logger.error("Failed to load cached courses: \(DiagnosticFailure(error).summary, privacy: .public)")
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
        let lease = sessionWork.lease
        // Always re-enable — the extension may have been disabled by macOS after
        // a Sparkle update or other bundle change.
        await reenableFileProviderExtensionAndWait()
        guard sessionWork.isCurrent(lease) else { return }

        do {
            try await addFileProviderDomain(site: site)
        } catch {
            logger.error("File Provider domain setup failed on relaunch: \(DiagnosticFailure(error).summary, privacy: .public)")
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

    /// An updated extension can be re-enabled and adopted without destroying
    /// its domain. Destructive recovery is reserved for the explicit reset flow.
    private func reregisterFileProviderDomain(site: MoodleSite) async {
        let lease = sessionWork.lease
        await reenableFileProviderExtensionAndWait()
        guard sessionWork.isCurrent(lease), !Task.isCancelled else { return }
        do {
            try await addFileProviderDomain(site: site)
            guard sessionWork.isCurrent(lease), !Task.isCancelled else { return }
            if let shared = await adoptSharedDatabaseWithRetry(siteID: site.id, seedFrom: database) {
                guard sessionWork.isCurrent(lease), !Task.isCancelled else { return }
                database = shared
                syncEngine = SyncEngine(provider: moodleClient, database: shared)
            }
        } catch {
            guard sessionWork.isCurrent(lease), !Task.isCancelled else { return }
            logger.error("Post-update Finder reconnection failed: \(DiagnosticFailure(error).summary, privacy: .public)")
            errorMessage = "Finder could not reconnect after the update. Your files were kept. Try Reset Finder."
        }
    }

    /// Re-enable the File Provider extension via `pluginkit`.
    ///
    /// macOS disables the extension when Sparkle replaces the app bundle.
    /// `NSFileProviderManager.add(domain)` does NOT re-enable it — only
    /// `pluginkit -e use` does.
    private func reenableFileProviderExtension() {
        Task { await reenableFileProviderExtensionAndWait() }
    }

    /// Runs `pluginkit` off the main actor so launch never blocks on it. Gives up
    /// after 10 s by terminating the process; callers that need ordering (domain
    /// registration) await this, and the rest use the fire-and-forget wrapper above.
    private func reenableFileProviderExtensionAndWait() async {
        let extensionBundleID = BundleIdentifiers.prefix + ".file-provider"
        let outcome = await Self.runPluginkitEnable(extensionBundleID: extensionBundleID, timeout: 10)

        switch outcome {
        case .exited(0):
            logger.info("Re-enabled File Provider extension via pluginkit")
        case .exited(let status):
            logger.warning("pluginkit exited with status \(status)")
        case .timedOut:
            logger.error("pluginkit did not exit within 10 s; terminated it")
        case .launchFailed(let message):
            logger.error("Failed to run pluginkit: \(message, privacy: .public)")
        }
    }

    private enum PluginkitOutcome: Sendable {
        case exited(Int32)
        case timedOut
        case launchFailed(String)
    }

    private nonisolated static func runPluginkitEnable(extensionBundleID: String, timeout: TimeInterval) async -> PluginkitOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-e", "use", "-i", extensionBundleID]

        return await withCheckedContinuation { (continuation: CheckedContinuation<PluginkitOutcome, Never>) in
            // Both the termination handler and the timeout race to resume; the first one wins.
            let gate = ResumeOnce(continuation)
            process.terminationHandler = { finished in
                gate.resume(.exited(finished.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                gate.resume(.launchFailed(error.localizedDescription))
                return
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                process.terminate()
                gate.resume(.timedOut)
            }
        }
    }

    private func addFileProviderDomain(site: MoodleSite) async throws {
        let attemptID = UUID()
        let journal = DiagnosticJournal(databasePath: databaseFilePath)
        if let path = databaseFilePath { diagnosticDatabasePaths.insert(path) }
        journal?.record(.init(attemptID: attemptID, process: .app, operation: .providerRegistration, outcome: .started))
        let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id))
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
        domain.isHidden = false

        do {
            try await NSFileProviderManager.add(domain)
            journal?.record(.init(attemptID: attemptID, process: .app, operation: .providerRegistration, outcome: .succeeded))
            logger.info("File Provider domain added: \(site.displayName, privacy: .private)")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
            journal?.record(.init(attemptID: attemptID, process: .app, operation: .providerRegistration, outcome: .succeeded))
            logger.info("File Provider domain already exists: \(site.displayName, privacy: .private)")
        } catch let error as NSError {
            journal?.record(.init(attemptID: attemptID, process: .app, operation: .providerRegistration,
                                  outcome: .failed, failure: DiagnosticFailure(error)))
            logger.error("Failed to add File Provider domain: \(DiagnosticFailure(error).summary, privacy: .public) [\(error.domain, privacy: .private):\(error.code)]")
            let detail = "\(error.localizedDescription) (\(error.domain):\(error.code))"
            throw FindleError.domainSetupFailed(detail: detail)
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
                    logger.info("Removed stale File Provider domain: \(pair.id, privacy: .private)")
                } catch {
                    logger.warning("Failed to remove domain \(pair.id, privacy: .private): \(DiagnosticFailure(error).summary, privacy: .public)")
                }
            }
        } catch {
            logger.warning("Could not enumerate existing File Provider domains: \(DiagnosticFailure(error).summary, privacy: .public)")
        }
    }

    // MARK: - Course Management

    func loadCourses() async {
        guard !isDatabaseTransitioning, !Task.isCancelled else { return }
        if let task = courseLoadTask { await task.value; return }
        let id = UUID()
        loadingCoursesID = id
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoadCourses()
        }
        courseLoadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        if loadingCoursesID == id {
            loadingCoursesID = nil
            courseLoadTask = nil
        }
    }

    private func performLoadCourses() async {
        guard !isDatabaseTransitioning, !Task.isCancelled else { return }
        guard let site = currentSite, let token = currentToken, let db = database else { return }
        guard let account = accounts.first else { return }
        let lease = sessionWork.lease

        do {
            let remoteCourses = try await moodleClient.fetchCourses(
                site: site,
                token: token,
                userID: account.userID ?? 0
            )
            guard sessionWork.isCurrent(lease), database === db else { return }
            try db.saveCourses(remoteCourses)
            // Re-read from database to pick up persisted custom folder names
            courses = try db.fetchCourses(siteID: site.id)
            reloadCourseTags()
            seedCourseSyncStatesFromCursors(siteID: site.id)
            loadCourseCovers()
            logger.info("Loaded \(self.courses.count) courses")
        } catch let error as FindleError where error.requiresReauthentication {
            guard sessionWork.isCurrent(lease), database === db else { return }
            logger.error("Failed to load courses: session expired")
            handleSessionExpired()
        } catch {
            guard sessionWork.isCurrent(lease), database === db else { return }
            logger.error("Failed to load courses: \(DiagnosticFailure(error).summary, privacy: .public)")
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
        guard let token = currentToken, let site = currentSite, !sessionWork.isTransitioning else { return }
        let lease = sessionWork.lease
        for course in courses {
            guard course.siteID == site.id, let remoteURL = course.imageURL, courseCoverImages[course.id] == nil else { continue }
            // Skip courses whose cover is already being loaded by an earlier pass.
            guard !coverDownloadsInFlight.contains(course.id) else { continue }

            // Key the cache file by site too, so a colliding course id across
            // two Moodle sites can't serve the wrong site's cover.
            let destination = coverCacheDirectory.appendingPathComponent("\(course.siteID)-\(course.id)")
            coverDownloadsInFlight.insert(course.id)
            coverTasks[course.id] = Task {
                await downloadCover(courseID: course.id, from: remoteURL, site: site, token: token, to: destination, lease: lease)
                guard sessionWork.isCurrent(lease) else { return }
                coverDownloadsInFlight.remove(course.id)
                coverTasks.removeValue(forKey: course.id)
            }
        }
    }

    private func downloadCover(courseID: Int, from remoteURL: URL, site: MoodleSite, token: AuthToken, to destination: URL,
                               lease: SessionWorkCoordinator.Lease) async {
        // Decoding images is kept off the main actor; only the finished NSImage is
        // published back here.
        if let cached = await Self.loadImage(at: destination) {
            guard sessionWork.isCurrent(lease) else { return }
            courseCoverImages[courseID] = cached
            return
        }

        do {
            guard sessionWork.isCurrent(lease) else { return }
            try await moodleClient.downloadFile(url: remoteURL, site: site, token: token, destination: destination)
            guard sessionWork.isCurrent(lease) else { return }
            if let image = await Self.loadImage(at: destination) {
                guard sessionWork.isCurrent(lease) else { return }
                courseCoverImages[courseID] = image
            } else {
                guard sessionWork.isCurrent(lease) else { return }
                // The download wasn't a valid image (e.g. an HTML error body):
                // drop it so a stale bad file doesn't linger and the next launch
                // can re-attempt cleanly.
                try? FileManager.default.removeItem(at: destination)
            }
        } catch {
            logger.debug("Course cover download failed for \(courseID): \(DiagnosticFailure(error).summary, privacy: .public)")
        }
    }

    private nonisolated static func loadImage(at url: URL) async -> NSImage? {
        await Task.detached(priority: .utility) { NSImage(contentsOf: url) }.value
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
        let lease = sessionWork.lease
        guard let rootURL = await fileProviderRootURL(for: site) else { return }
        guard sessionWork.isCurrent(lease), database === db else { return }

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
            // macOS stores tags as "Name\nColorIndex" or just "Name". Splitting an
            // empty or newline-only string yields no parts, so guard before indexing.
            let parts = raw.split(separator: "\n", maxSplits: 1)
            guard let firstPart = parts.first else { return nil }
            let name = String(firstPart)
            guard !name.isEmpty else { return nil }
            let colorIndex = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            let color = FinderTag.Color(rawValue: colorIndex) ?? .none
            return FinderTag(name: name, color: color)
        }
    }

    // MARK: - Course Customization

    func updateCustomFolderName(for course: MoodleCourse, name: String?) {
        guard !isDatabaseTransitioning, let db = database, let site = currentSite,
              course.siteID == site.id else { return }
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
            logger.error("Failed to update custom folder name: \(DiagnosticFailure(error).summary, privacy: .public)")
        }
    }

    func updateCourseCustomIcon(for course: MoodleCourse, iconName: String?) {
        guard !isDatabaseTransitioning, let db = database, course.siteID == currentSite?.id else { return }
        do {
            try db.updateCourseCustomIconName(courseID: course.id, siteID: course.siteID, iconName: iconName)
            if let index = courses.firstIndex(where: { $0.id == course.id && $0.siteID == course.siteID }) {
                courses[index].customIconName = iconName
            }
        } catch {
            logger.error("Failed to update custom icon: \(DiagnosticFailure(error).summary, privacy: .public)")
        }
    }

    func setCourseSyncEnabled(_ enabled: Bool, for course: MoodleCourse) {
        guard !isDatabaseTransitioning, let db = database, let site = currentSite,
              course.siteID == site.id else { return }
        let lease = sessionWork.lease
        let revision = UUID()
        subscriptionRevisions[course.id] = revision
        subscriptionTasks.removeValue(forKey: course.id)?.cancel()
        let newState: CourseSubscriptionState = enabled ? .discovered : .unsubscribed
        do {
            // Update selection immediately; sync's database commit guard also
            // observes this flag while cancellation reaches its network work.
            try db.updateCourseSubscription(courseID: course.id, siteID: course.siteID, state: newState)
            if let index = courses.firstIndex(where: { $0.id == course.id && $0.siteID == course.siteID }) {
                courses[index].isSyncEnabled = enabled
            }
            guard !enabled else { return }
            let engine = syncEngine
            subscriptionTasks[course.id] = Task {
                await engine?.cancelSync(courseID: course.id)
                guard sessionWork.isCurrent(lease), database === db,
                      subscriptionRevisions[course.id] == revision else { return }
                defer {
                    if subscriptionRevisions[course.id] == revision {
                        subscriptionTasks.removeValue(forKey: course.id)
                    }
                }
                do {
                    try db.deleteItems(courseID: course.id, siteID: site.id)
                    try db.deleteCourseOutline(courseID: course.id, siteID: site.id)
                    SpotlightIndexer.shared.removeItems(forCourse: course.id, siteID: course.siteID)
                    signalFileProviderChanges()
                    await reconcilePersonalFiles()
                } catch {
                    guard sessionWork.isCurrent(lease) else { return }
                    logger.error("Failed to remove unsubscribed course: \(DiagnosticFailure(error).summary, privacy: .public)")
                }
            }
        } catch {
            logger.error("Failed to update course sync state: \(DiagnosticFailure(error).summary, privacy: .public)")
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
        guard !isDatabaseTransitioning, let db = database, let site = currentSite,
              course.siteID == site.id else { return }
        do {
            try db.saveCourseTags(tags, courseID: course.id, siteID: course.siteID)
            courseTags[course.id] = tags.isEmpty ? nil : tags

            // Update the course root item's tag data so the File Provider sees it
            let courseItemID = "course-\(site.id)-\(course.id)"
            let tagData = FinderTag.tagData(from: tags)
            try db.updateItemTagData(id: courseItemID, tagData: tagData)
            signalFileProviderChanges()
        } catch {
            logger.error("Failed to update course tags: \(DiagnosticFailure(error).summary, privacy: .public)")
        }
    }

    // MARK: - Personal Files

    /// Brings the database in line with the personal files folder for the current site.
    ///
    /// The work runs off the main actor. A call that arrives while another run is in
    /// flight waits for it, so two runs never write the database at the same time.
    /// Failures are logged rather than shown, because the rest of the app works without them.
    func reconcilePersonalFiles() async {
        guard !isDatabaseTransitioning, !Task.isCancelled,
              let database, let site = currentSite, currentToken != nil else { return }
        let lease = sessionWork.lease
        let store = personalFileStore
        let siteID = site.id
        let siteName = site.displayName
        let previous = personalFilesReconcileTask

        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.sessionWork.isCurrent(lease), self.database === database else { return }
            do {
                let worker = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    return try PersonalFilesReconciler(store: store, database: database)
                        .reconcile(siteID: siteID, siteName: siteName)
                }
                let changed = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard self.sessionWork.isCurrent(lease), self.database === database else { return }
                if changed {
                    self.signalFileProviderChanges()
                }
                self.ensureDocumentsShortcut()
            } catch {
                guard self.sessionWork.isCurrent(lease) else { return }
                self.logger.error("Personal files reconcile failed: \(DiagnosticFailure(error).summary, privacy: .public)")
            }
        }
        personalFilesReconcileTask = task
        await task.value
    }

    /// Starts watching the personal files folder for the session. Called after the session's first
    /// reconcile, so the folder exists and the database is already in step with it.
    func startPersonalFilesWatcher() {
        guard !isDatabaseTransitioning, currentSite != nil, currentToken != nil, !sessionExpired else { return }
        let lease = sessionWork.lease
        let root = personalFileStore.rootURL
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        personalFilesWatcher?.stop()
        // Reconciling writes extended attributes and may rename clashing files, and both
        // of those emit events. That does not loop: the follow-up run finds nothing new to
        // write, so it emits nothing and the cycle ends. The watcher's quiet period also
        // keeps runs to one per burst.
        let watcher = PersonalFilesWatcher(rootURL: root) { [weak self] in
            Task { @MainActor in
                guard let self, self.sessionWork.isCurrent(lease) else { return }
                await self.reconcilePersonalFiles()
            }
        }
        watcher.start()
        personalFilesWatcher = watcher
    }

    /// Stops watching the personal files folder. Called when the session ends.
    func stopPersonalFilesWatcher() {
        personalFilesWatcher?.stop()
        personalFilesWatcher = nil
    }

    /// Opens the site's personal files folder in Finder, creating it first if needed.
    func showPersonalFiles() {
        do {
            let url: URL
            if let site = currentSite {
                url = try personalFileStore.siteDirectory(siteID: site.id, siteName: site.displayName)
            } else {
                url = personalFileStore.rootURL
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            _ = NSWorkspace.shared.open(url)
        } catch {
            logger.error("Could not open personal files: \(DiagnosticFailure(error).summary, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    /// Places a Finder alias to the personal files folder in Documents.
    ///
    /// Runs once automatically: after the first successful reconcile the flag is set and the
    /// alias is attempted. `force` skips the flag, for the Settings button. Nothing is written
    /// when anything already exists at the alias path, so a shortcut the user moved or
    /// renamed is never replaced. A symbolic link would not survive iCloud "Desktop & Documents"
    /// syncing, which is why this is an alias.
    ///
    /// The result tells the caller what is now at the alias path. An automatic call that finds the
    /// attempt already made returns `.alreadyExists` without touching the disk, so only `force`
    /// calls need to report on the outcome.
    @discardableResult
    func ensureDocumentsShortcut(force: Bool = false) -> DocumentsShortcutResult {
        let aliasURL = Self.realHomeDirectory
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(PersonalFileStore.configuredFolderName)

        if !force {
            guard !userDefaults.bool(forKey: Self.personalFilesShortcutAttemptedKey) else {
                return .alreadyExists(aliasURL)
            }
            userDefaults.set(true, forKey: Self.personalFilesShortcutAttemptedKey)
        }

        let root = personalFileStore.rootURL
        guard (try? FileManager.default.attributesOfItem(atPath: aliasURL.path)) == nil else {
            return .alreadyExists(aliasURL)
        }

        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bookmark = try root.bookmarkData(options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil)
            try URL.writeBookmarkData(bookmark, to: aliasURL)
            logger.info("Added personal files shortcut in Documents")
            return .created(aliasURL)
        } catch {
            logger.error("Could not add personal files shortcut: \(DiagnosticFailure(error).summary, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    /// The account's home directory. `NSHomeDirectory()` returns the sandbox container
    /// instead, which is not where the user expects Documents to be.
    private static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    // MARK: - Sync

    func syncAll() async {
        guard !sessionWork.isTransitioning, !Task.isCancelled, !sessionExpired else { return }
        // Only one sync pass runs at a time. Callers that arrive mid-sync wait for
        // the pass already in flight instead of starting an overlapping one.
        if let inFlight = syncAllTask {
            await inFlight.value
            return
        }

        let lease = sessionWork.lease
        let task = Task { [weak self] in
            await self?.runSyncAll()
            if let self, self.sessionWork.owns(lease) { self.syncAllTask = nil }
        }
        syncAllTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func runSyncAll() async {
        guard !isDatabaseTransitioning else {
            logger.info("Skipping sync while the shared database is transitioning")
            return
        }
        guard let site = currentSite, let token = currentToken, let engine = syncEngine else { return }
        let lease = sessionWork.lease

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
                guard self.sessionWork.isCurrent(lease) else { return }
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
        defer { if sessionWork.owns(lease) { syncProgressDetail = nil } }

        // Publish each course to Finder the moment it lands in the database.
        // Signalling only after the whole run meant the first course's files
        // stayed invisible until the last course finished.
        let signalDomainID = BundleIdentifiers.fileProviderDomainID(siteID: site.id)
        let signalDisplayName = site.displayName
        let signalLogger = logger

        let report = await engine.syncAllCourses(
            site: site,
            token: token,
            courses: enabledCourses,
            onCourseSynced: { _ in
                Task.detached {
                    await Self.performSignalEnumerators(
                        domainID: signalDomainID,
                        displayName: signalDisplayName,
                        logger: signalLogger
                    )
                }
            }
        )
        progressTask.cancel()
        await progressTask.value
        // A retired session may finish after a database/account transition.
        guard sessionWork.owns(lease), currentSite?.id == site.id, syncEngine === engine, !isDatabaseTransitioning else { return }
        applySyncReport(report)
        guard !report.isNoOp else { return }
        if report.succeededCount > 0 || report.incompleteCount > 0 {
            signalFileProviderChanges()
            indexForSpotlight()
        }
        guard !report.wasCancelled, !report.requiresReauthentication else { return }
        await reconcilePersonalFiles()
        guard sessionWork.isCurrent(lease), syncEngine === engine else { return }
        if SyncReportPresentation(report: report).shouldNotifyCompletion {
            notifySyncCompletedIfEnabled(courseCount: report.succeededCount)
        }
        trackingRefreshTask?.cancel()
        trackingRefreshTask = Task { [weak self] in
            await self?.refreshTracking()
        }
    }

    private func applySyncReport(_ report: SyncRunReport) {
        lastSyncReport = report
        for course in report.courses {
            switch course.outcome {
            case .succeeded: courseSyncStates[course.courseID] = .synced
            case .failed: courseSyncStates[course.courseID] = .error
            case .incomplete, .cancelled, .skipped: courseSyncStates[course.courseID] = .stale
            }
        }
        let presentation = SyncReportPresentation(report: report)
        let stored = SyncReportStore(defaults: userDefaults).save(report, previousSuccess: lastSyncDate)
        lastSyncDate = stored.lastSuccessfulSync
        errorMessage = presentation.message
        if report.requiresReauthentication { handleSessionExpired() }
        else if report.isNoOp { syncStatus = .idle }
        else if report.allSucceeded { syncStatus = .completed }
        else { syncStatus = .error(presentation.message ?? "Sync did not finish. Try again.") }
    }

    private func restoreSyncReport(siteID: String) {
        let snapshot = SyncReportStore(defaults: userDefaults).load(siteID: siteID)
        lastSyncReport = snapshot?.report
        lastSyncDate = snapshot?.lastSuccessfulSync
        errorMessage = nil
        syncStatus = .idle
        guard let report = snapshot?.report else { return }
        let presentation = SyncReportPresentation(report: report)
        errorMessage = presentation.message
        syncStatus = report.allSucceeded ? .completed : report.isNoOp ? .idle : .error(presentation.message ?? "Sync did not finish.")
        for result in report.courses where courses.contains(where: { $0.id == result.courseID && $0.isSyncEnabled }) {
            switch result.outcome {
            case .succeeded: courseSyncStates[result.courseID] = .synced
            case .failed: courseSyncStates[result.courseID] = .error
            case .incomplete, .cancelled, .skipped: courseSyncStates[result.courseID] = .stale
            }
        }
    }

    private func cancelTrackingRefresh() async {
        if let task = trackingRefreshTask {
            task.cancel()
            await task.value
        }
        trackingRefreshTask = nil
    }

    @discardableResult
    func syncCourse(_ course: MoodleCourse) async -> Bool {
        guard !isDatabaseTransitioning, !Task.isCancelled else { return false }
        let id = UUID()
        let task = Task { await performSyncCourse(course) }
        courseSyncTasks[id] = task
        defer { courseSyncTasks.removeValue(forKey: id) }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    private func performSyncCourse(_ course: MoodleCourse) async -> Bool {
        guard !isDatabaseTransitioning else {
            logger.info("Skipping course sync while the shared database is transitioning")
            return false
        }
        guard !sessionExpired, !Task.isCancelled,
              let site = currentSite, let token = currentToken, let engine = syncEngine,
              course.siteID == site.id else { return false }
        let lease = sessionWork.lease

        errorMessage = nil
        syncStatus = .syncing(progress: 0)
        courseSyncStates[course.id] = .syncing

        let report = await engine.syncAllCourses(site: site, token: token, courses: [course])
        guard sessionWork.owns(lease), currentSite?.id == site.id, syncEngine === engine, !isDatabaseTransitioning else { return false }
        applySyncReport(report)
        if report.succeededCount > 0 || report.incompleteCount > 0 {
            signalFileProviderChanges()
            // Moodle files can clash with personal files; reconciliation preserves both.
            await reconcilePersonalFiles()
        }
        return report.allSucceeded
    }

    // MARK: - Coursework Tracking

    /// Fetch read-only coursework tracking (assignments + submission status,
    /// grades, quizzes + attempts) for the sync-enabled courses and store it for
    /// the MCP server. Best-effort, but a *failed* list fetch is never persisted
    /// as an empty result — the replace-all saves would otherwise wipe good data
    /// on a transient network/token error. Independent per-item calls run with
    /// bounded concurrency instead of one-at-a-time.
    func refreshTracking() async {
        guard !isDatabaseTransitioning, !Task.isCancelled else { return }
        guard let site = currentSite, let token = currentToken, let db = database,
              let userID = accounts.first?.userID else { return }
        let lease = sessionWork.lease
        let courseIDs = courses.filter(\.isSyncEnabled).map(\.id)
        guard !courseIDs.isEmpty else { return }
        let client = moodleClient

        // The save calls replace everything stored for the site, so a failed fetch
        // must fall back to the previously stored rows rather than write defaults.
        let storedAssignments = Dictionary(
            ((try? db.fetchAssignments(siteID: site.id)) ?? []).map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let storedGrades = (try? db.fetchGradeItems(siteID: site.id)) ?? []

        // Assignments (+ submission status). Persist only if the list fetch worked.
        if let base = try? await client.fetchAssignments(site: site, token: token, courseIDs: courseIDs) {
            guard sessionWork.isCurrent(lease), database === db else { return }
            let enriched = await Self.boundedMap(base) { assignment in
                var a = assignment
                if let status = try? await client.fetchSubmissionStatus(site: site, token: token, assignmentID: assignment.id) {
                    a.submitted = status.submitted
                    a.graded = status.graded
                    a.grade = status.grade
                } else if let stored = storedAssignments[assignment.id] {
                    a.submitted = stored.submitted
                    a.graded = stored.graded
                    a.grade = stored.grade
                }
                return a
            }
            guard sessionWork.isCurrent(lease), database === db else { return }
            try? db.saveAssignments(enriched, siteID: site.id)
        }
        guard sessionWork.isCurrent(lease), database === db else { return }

        // Grades, per course. Skip the save entirely if every course fetch failed.
        // Courses whose fetch failed keep their previously stored grade items.
        let gradeResults = await Self.boundedMap(courseIDs) { courseID -> [MoodleGradeItem]? in
            try? await client.fetchGrades(site: site, token: token, courseID: courseID, userID: userID)
        }
        guard sessionWork.isCurrent(lease), database === db else { return }
        if gradeResults.contains(where: { $0 != nil }) {
            var mergedGrades: [MoodleGradeItem] = []
            for (courseID, result) in zip(courseIDs, gradeResults) {
                if let items = result {
                    mergedGrades += items
                } else {
                    mergedGrades += storedGrades.filter { $0.courseID == courseID }
                }
            }
            try? db.saveGradeItems(mergedGrades, siteID: site.id)
        }

        // Quizzes (+ attempts). Persist only if the quiz-list fetch worked.
        if let quizzes = try? await client.fetchQuizzes(site: site, token: token, courseIDs: courseIDs) {
            guard sessionWork.isCurrent(lease), database === db else { return }
            try? db.saveQuizzes(quizzes, siteID: site.id)

            let attemptResults = await Self.boundedMap(quizzes) { quiz -> [MoodleQuizAttempt]? in
                try? await client.fetchQuizAttempts(site: site, token: token, quizID: quiz.id, userID: userID)
            }
            guard sessionWork.isCurrent(lease), database === db else { return }
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
                if next < items.count, !Task.isCancelled {
                    let index = next
                    next += 1
                    group.addTask { (index, await transform(items[index])) }
                }
            }
            return results.compactMap { $0 }
        }
    }

    // MARK: - Session Recovery

    /// Retire every producer before a caller replaces or clears its database.
    /// Explicit transitions own this boundary; bootstrap must never call it.
    func beginSessionTransition(
        preservingAuthentication attempt: SessionWorkCoordinator.AuthenticationLease? = nil
    ) async -> Bool {
        let bootstrap = sessionBootstrapTask
        let automatic = automaticSyncTask
        let syncing = syncAllTask
        let tracking = trackingRefreshTask
        let personal = personalFilesReconcileTask
        let restore = keychainRestoreTask
        let loading = courseLoadTask
        let authenticationSetup = authenticationSetupTask
        let authenticationRequest = authenticationRequestTask
        let subscriptions = Array(subscriptionTasks.values)
        let courseSyncs = Array(courseSyncTasks.values)
        let requested = requestedSyncTask
        let covers = Array(coverTasks.values)
        let engine = syncEngine

        return await sessionWork.beginTransition(preservingAuthentication: attempt) {
            activeWebAuthSession?.cancel()
            activeWebAuthSession = nil
            stopPersonalFilesWatcher()
            bootstrap?.cancel()
            automatic?.cancel()
            syncing?.cancel()
            tracking?.cancel()
            personal?.cancel()
            restore?.cancel()
            loading?.cancel()
            authenticationSetup?.cancel()
            authenticationRequest?.cancel()
            subscriptions.forEach { $0.cancel() }
            courseSyncs.forEach { $0.cancel() }
            requested?.cancel()
            covers.forEach { $0.cancel() }
            sessionBootstrapTask = nil
            automaticSyncTask = nil
            syncAllTask = nil
            trackingRefreshTask = nil
            personalFilesReconcileTask = nil
            keychainRestoreTask = nil
            courseLoadTask = nil
            authenticationSetupTask = nil
            authenticationRequestTask = nil
            subscriptionTasks.removeAll()
            subscriptionRevisions.removeAll()
            courseSyncTasks.removeAll()
            requestedSyncTask = nil
            coverTasks.removeAll()
            coverDownloadsInFlight.removeAll()
            loadingCoursesID = nil
            syncProgressDetail = nil
            lastAppliedSyncInterval = -1
        } drain: {
            await engine?.stopAllSyncs()
            _ = try? await bootstrap?.value
            await automatic?.value
            await syncing?.value
            await tracking?.value
            await personal?.value
            await restore?.value
            await loading?.value
            _ = try? await authenticationSetup?.value
            _ = try? await authenticationRequest?.value
            for task in subscriptions { await task.value }
            for task in courseSyncs { _ = await task.value }
            await requested?.value
            for task in covers { await task.value }
        }
    }

    func endSessionTransition() {
        sessionWork.endTransition()
        guard incompatibleDatabaseError == nil, currentSite != nil,
              currentToken != nil, database != nil, !sessionExpired else { return }
        startPersonalFilesWatcher()
        refreshAutomaticSyncSchedule()
    }

    private func beginExplicitSessionTransition() async -> Bool {
        // A logout arriving during credential persistence invalidates that
        // attempt immediately, then waits for its drain to release ownership.
        sessionWork.invalidateAuthentication()
        activeWebAuthSession?.cancel()
        while !Task.isCancelled {
            if await beginSessionTransition() { return true }
            await sessionWork.waitForTransition()
        }
        return false
    }

    /// Called when a sync or load fails because the session is no longer valid.
    /// Surfaces a reconnect prompt and stops the automatic sync loop so we don't
    /// keep hammering the server with a dead token.
    private func handleSessionExpired() {
        logger.warning("Session expired — prompting user to reconnect")
        sessionExpired = true
        syncStatus = .error(FindleError.tokenExpired.localizedDescription)
        automaticSyncTask?.cancel()
        automaticSyncTask = nil
        lastAppliedSyncInterval = -1
    }

    /// Return to sign-in after the session expired, keeping everything on disk.
    ///
    /// Unlike `logout()` this leaves the database, the File Provider domain and
    /// the user's own files in place. Only the dead token is dropped, so Finder
    /// shows the domain as signed out until `persistSignIn` stores a new one.
    func reconnect() async {
        guard await beginExplicitSessionTransition() else { return }
        defer { endSessionTransition() }
        sessionExpired = false
        syncEngine = nil

        if let account = accounts.first {
            try? KeychainManager.shared.deleteToken(forAccount: account.id)
        }

        currentToken = nil
        syncStatus = .idle
        currentScreen = .onboarding
    }

    /// Clear a surfaced error banner.
    func dismissError() {
        errorMessage = nil
        if case .error = syncStatus {
            // Dismissing a message must not turn a failed attempt into a completed sync.
            syncStatus = lastSyncReport?.allSucceeded == true ? .completed : .idle
        }
    }

    // MARK: - Notifications

    private func notifySyncCompletedIfEnabled(courseCount: Int) {
        guard userDefaults.bool(forKey: "notifyOnSyncComplete") else { return }
        let lease = sessionWork.lease

        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard sessionWork.isCurrent(lease) else { return }

            var authorized = settings.authorizationStatus == .authorized
            if settings.authorizationStatus == .notDetermined {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized, sessionWork.isCurrent(lease) else { return }

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
        let lease = sessionWork.lease
        let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id))
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)

        for attempt in 1...maxAttempts {
            guard sessionWork.isCurrent(lease) else { return }
            guard let manager = NSFileProviderManager(for: domain) else {
                logger.warning("No NSFileProviderManager for domain \(domainID.rawValue, privacy: .private) while resolving authentication (attempt \(attempt))")
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
            guard sessionWork.isCurrent(lease) else { return }

            if let signalError = signalError as? NSError {
                logger.warning("Failed to resolve File Provider authentication (attempt \(attempt)): \(DiagnosticFailure(signalError).summary, privacy: .public) [\(signalError.domain, privacy: .private):\(signalError.code)]")
                if attempt < maxAttempts {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
            } else {
                logger.info("Resolved File Provider authentication state for \(site.displayName, privacy: .private)")
                break
            }
        }

        signalFileProviderChanges(for: site)
    }

    // MARK: - Logout

    func logout() async {
        guard await beginExplicitSessionTransition() else { return }
        defer { endSessionTransition() }
        let account = accounts.first
        syncEngine = nil

        // Signing out must preserve the user's bytes, including legacy content
        // that has not yet reached the durable personal folder.
        var canClearMetadata = true
        if let site = currentSite {
            do {
                guard let database else { throw AccountReconnectError.storageUnavailable }
                guard let location = try sharedDatabaseLocation(siteID: site.id) else {
                    throw AccountReconnectError.storageUnavailable
                }
                let scope = location.securityScopedDirectoryURL
                let didAccess = scope.startAccessingSecurityScopedResource()
                defer { if didAccess { scope.stopAccessingSecurityScopedResource() } }
                let store = personalFileStore
                let archive = store.rootURL.appendingPathComponent("Recovery", isDirectory: true)
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try await Task.detached(priority: .utility) {
                    try PersonalFileRecovery.prepare(database: database, store: store,
                                                     siteID: site.id, siteName: site.displayName,
                                                     archiveRoot: archive, providerStateRoot: scope)
                }.value
                userDefaults.set(archive.path, forKey: "lastProviderRecoveryPath")
                let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id))
                let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
                if let preserved = try await NSFileProviderManager.remove(domain, mode: .preserveDownloadedUserData) {
                    userDefaults.set(preserved.path, forKey: "lastProviderRecoveryPath")
                }
            } catch {
                canClearMetadata = false
                logger.error("Signed out while preserving Finder recovery state: \(DiagnosticFailure(error).summary, privacy: .public)")
                errorMessage = "Signed out. Finder files and recovery information were kept because cleanup could not finish."
            }
        }

        // Clear Spotlight index
        SpotlightIndexer.shared.removeAllItems()

        // Clear Keychain
        if let account { try? KeychainManager.shared.deleteToken(forAccount: account.id) }

        // Clear database before revoking security-scoped access
        if canClearMetadata {
            try? database?.deleteAllData()
            if let bootstrapDatabase = try? Database() {
                try? bootstrapDatabase.deleteAllData()
            }
        }
        database = nil
        databaseSecurityScopedURL?.stopAccessingSecurityScopedResource()
        databaseSecurityScopedURL = nil
        database = try? Database()
        if canClearMetadata { userDefaults.removeObject(forKey: Self.currentSiteIDKey) }

        if let account { SyncReportStore(defaults: userDefaults).remove(siteID: account.siteID) }
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
        sessionExpired = false
        lastSyncDate = nil
        lastSyncReport = nil
        syncStatus = .idle
        currentScreen = .onboarding
    }

    // MARK: - Diagnostics

    func rebuildIndex() async {
        guard !isDatabaseTransitioning else { return }
        try? database?.rebuildIndex()
        await syncAll()
    }

    func openFileProviderInFinder(selecting course: MoodleCourse? = nil) async {
        guard let site = currentSite else {
            logger.warning("Open in Finder: no current site")
            return
        }

        guard let rootURL = await fileProviderRootURL(for: site) else {
            logger.warning("Open in Finder: File Provider root URL not available")
            return
        }

        let targetURL: URL
        if let course {
            let courseURL = rootURL.appendingPathComponent(course.effectiveFolderName, isDirectory: true)
            targetURL = FileManager.default.fileExists(atPath: courseURL.path) ? courseURL : rootURL
        } else {
            targetURL = rootURL
        }

        // The user-visible File Provider URL is security-scoped, so hold access
        // while opening it. Open it with NSWorkspace from this process: shelling
        // out to /usr/bin/open does not work, because the spawned tool inherits
        // the app sandbox and its LaunchServices request to open a path outside
        // the container is silently denied (no kernel sandbox violation, no
        // effect).
        let didAccess = targetURL.startAccessingSecurityScopedResource()
        defer { if didAccess { targetURL.stopAccessingSecurityScopedResource() } }

        do {
            _ = try await NSWorkspace.shared.open(targetURL, configuration: NSWorkspace.OpenConfiguration())
            logger.info("Opened \(targetURL.lastPathComponent, privacy: .private) in Finder")
        } catch {
            // Revealing (selecting the item in its parent) can still succeed when
            // opening the folder itself does not.
            logger.warning("NSWorkspace.open failed (\(DiagnosticFailure(error).summary, privacy: .public)); revealing in Finder instead")
            NSWorkspace.shared.activateFileViewerSelecting([targetURL])
        }
    }

    func resetProvider() async {
        if let incompatibleDatabaseError {
            errorMessage = incompatibleDatabaseError.localizedDescription
            return
        }
        guard let site = currentSite, let sourceDatabase = database else { return }
        guard await beginSessionTransition() else { return }
        defer { endSessionTransition() }

        let domainID = NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id))
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
        var resetEvents: [DiagnosticEvent] = []
        var lastUsableDatabase = sourceDatabase
        let coordinator = ProviderResetCoordinator<Database>(operations: .init(
            prepareFallback: {
                // Token accessibility and a verified, durable fallback are both
                // required before the domain can be removed.
                if let token = self.currentToken,
                   let account = self.accounts.first(where: { $0.siteID == site.id && $0.state.isConnected }) {
                    try KeychainManager.shared.storeToken(token.token, forAccount: account.id)
                }
                return try await self.snapshotCurrentDataToBootstrap(from: sourceDatabase, siteID: site.id)
            },
            bind: { handle in
                lastUsableDatabase = handle
                self.database = handle
                self.diagnosticDatabasePaths.insert(handle.filePath)
                self.syncEngine = SyncEngine(provider: self.moodleClient, database: handle)
                // The original journal may disappear with its provider domain.
                // Carry the attempt's start event to every replacement handle.
                if let journal = DiagnosticJournal(databasePath: handle.filePath) {
                    for event in resetEvents { journal.record(event) }
                }
            },
            removeDomain: {
                // Preserve downloaded/dirty user-visible files in addition to
                // relocating hidden legacy originals during fallback preparation.
                let preserved = try await NSFileProviderManager.remove(domain, mode: .preserveDownloadedUserData)
                if let preserved {
                    self.userDefaults.set(preserved.path, forKey: "lastProviderRecoveryPath")
                }
                self.databaseSecurityScopedURL?.stopAccessingSecurityScopedResource()
                self.databaseSecurityScopedURL = nil
            },
            addDomain: {
                await self.reenableFileProviderExtensionAndWait()
                try Task.checkCancellation()
                try await self.addFileProviderDomain(site: site)
            },
            seedDatabase: { fallback in
                var lastError: any Error = FindleError.databaseError(detail: "Finder's state directory is not available yet.")
                for attempt in 1...5 {
                    try Task.checkCancellation()
                    do {
                        if let restored = try self.openSharedDatabase(siteID: site.id, seedFrom: fallback) {
                            try restored.verifyCompleteRecoveryState()
                            return restored
                        }
                    } catch let error as UnsupportedDatabaseSchemaError {
                        throw error
                    } catch { lastError = error }
                    if attempt < 5 { try await Task.sleep(for: .seconds(TimeInterval(attempt))) }
                }
                throw lastError
            }
        ))
        do {
            try await coordinator.run { event in
                resetEvents.append(event)
                DiagnosticJournal(databasePath: self.database?.filePath ?? lastUsableDatabase.filePath)?.record(event)
            }
            if let database { courses = try database.fetchCourses(siteID: site.id) }
            reloadCourseTags()
            errorMessage = nil
            await resolveFileProviderAuthentication(for: site)
        } catch is CancellationError {
            errorMessage = "Finder reset was interrupted. Your recovery data was kept. Try Reset Finder again."
        } catch {
            logger.error("Finder reset failed: \(DiagnosticFailure(error).summary, privacy: .public)")
            if let failure = error as? ProviderResetCoordinator<Database>.Failure,
               let incompatible = failure.underlying as? UnsupportedDatabaseSchemaError {
                rejectIncompatibleDatabase(incompatible)
                // Keep the verified handle available for recovery/export while
                // the incompatible-schema guard prevents any further sync.
                database = lastUsableDatabase
                errorMessage = incompatible.localizedDescription
            } else {
                errorMessage = error.localizedDescription
            }
        }
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
        guard !sessionWork.isTransitioning, !Task.isCancelled else { return }
        let lease = sessionWork.lease
        let activeDatabase: Database
        do {
            if let sharedDatabase = try openSharedDatabase(siteID: site.id, seedFrom: database) {
                activeDatabase = sharedDatabase
                self.database = sharedDatabase
            } else {
                activeDatabase = database
            }
        } catch is UnsupportedDatabaseSchemaError {
            return
        } catch {
            logger.error("Failed to adopt File Provider database: \(DiagnosticFailure(error).summary, privacy: .public)")
            activeDatabase = database
        }

        // Retire the previous session before the new engine takes over, so the old
        // and new engines never write to the shared database at the same time.
        sessionBootstrapTask?.cancel()
        let stopPreviousEngine: Task<Void, Never>? = syncEngine.map { previousEngine in
            Task { await previousEngine.stopAllSyncs() }
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
            restoreSyncReport(siteID: site.id)
        } catch {
            logger.error("Failed to load cached courses: \(DiagnosticFailure(error).summary, privacy: .public)")
        }

        sessionBootstrapTask = Task { [weak self] in
            guard let self else { return }
            // Don't touch the shared database until the previous engine has stopped.
            await stopPreviousEngine?.value
            guard self.sessionWork.isCurrent(lease) else { return }

            if self.appVersionChanged() {
                await self.reregisterFileProviderDomain(site: site)
            } else {
                await self.ensureFileProviderDomain(site: site)
            }
            guard self.sessionWork.isCurrent(lease) else { return }

            // Re-adopt after registration, including the normal relaunch path.
            // The initial synchronous attempt can race fileproviderd while it
            // restores the domain, so do not let the first sync use bootstrap
            // storage when the state database becomes available moments later.
            if let sourceDatabase = self.database,
               let sharedDatabase = await self.adoptSharedDatabaseWithRetry(siteID: site.id, seedFrom: sourceDatabase) {
                guard self.sessionWork.isCurrent(lease) else { return }
                self.database = sharedDatabase
                self.syncEngine = SyncEngine(provider: self.moodleClient, database: sharedDatabase)
            }
            guard self.sessionWork.isCurrent(lease), self.incompatibleDatabaseError == nil else { return }

            // Clear any downloads left mid-flight by a previous run so they
            // don't appear stuck in-progress.
            _ = try? self.database?.resetStaleDownloads(siteID: site.id)

            // Pick up personal files left on disk before courses load, so their rows exist in Finder.
            await self.reconcilePersonalFiles()
            guard self.sessionWork.isCurrent(lease) else { return }
            self.startPersonalFilesWatcher()

            guard self.sessionWork.isCurrent(lease) else { return }
            await self.resolveFileProviderAuthentication(for: site)
            guard self.sessionWork.isCurrent(lease) else { return }
            await self.loadCourses()
            guard self.sessionWork.isCurrent(lease) else { return }
            await self.importFinderTagsFromDisk()
            guard self.sessionWork.isCurrent(lease) else { return }
            if triggerLaunchSync && self.userDefaults.bool(forKey: Self.syncOnLaunchKey) {
                await self.syncAll()
            }
            guard self.sessionWork.isCurrent(lease) else { return }
            self.refreshAutomaticSyncSchedule()
        }
    }

    private func localContentDirectory(for databaseURL: URL) -> URL {
        let databaseDirectory = databaseURL.deletingLastPathComponent()
        if databaseDirectory.lastPathComponent == "Findle",
           databaseDirectory.deletingLastPathComponent().lastPathComponent == ".FindleState" {
            return databaseDirectory
                .deletingLastPathComponent()
                .appendingPathComponent("LocalContent", isDirectory: true)
        }
        return databaseDirectory.appendingPathComponent("LocalContent", isDirectory: true)
    }

    private func snapshotCurrentDataToBootstrap(from sourceDatabase: Database, siteID: String) async throws -> Database {
        let store = personalFileStore
        let archiveRoot = store.rootURL.appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard let location = try sharedDatabaseLocation(siteID: siteID) else {
            throw FindleError.databaseError(detail: "Finder's state directory is unavailable. Reset was stopped to preserve personal files.")
        }
        let scope = location.securityScopedDirectoryURL
        let accessing = scope.startAccessingSecurityScopedResource()
        defer { if accessing { scope.stopAccessingSecurityScopedResource() } }
        let siteName = currentSite?.displayName ?? siteID
        let providerDatabaseURL = location.databaseURL
        // This worker is always awaited, even after cancellation. The reset
        // coordinator checks cancellation before binding/removing the domain.
        let fallback = try await Task.detached(priority: .utility) {
            try sourceDatabase.verifyProviderResetSource(at: providerDatabaseURL)
            let bootstrap = try Database()
            let providerRoot = scope.resolvingSymlinksInPath().standardizedFileURL.path
            let bootstrapPath = URL(fileURLWithPath: bootstrap.filePath).resolvingSymlinksInPath().standardizedFileURL.path
            guard !bootstrapPath.hasPrefix(providerRoot + "/") else {
                throw FindleError.databaseError(detail: "The recovery database must be outside Finder's state directory.")
            }
            try PersonalFileRecovery.prepare(
                database: sourceDatabase, store: store, siteID: siteID,
                siteName: siteName, archiveRoot: archiveRoot, providerStateRoot: scope
            )
            guard try sourceDatabase.fetchSite(id: siteID) != nil,
                  try sourceDatabase.fetchAccounts().contains(where: { $0.siteID == siteID && $0.state.isConnected }) else {
                throw FindleError.databaseError(detail: "The recovery database does not contain the connected account.")
            }
            let snapshot = archiveRoot.appendingPathComponent("index.db")
            try sourceDatabase.writeRecoverySnapshot(to: snapshot)
            if URL(fileURLWithPath: sourceDatabase.filePath).resolvingSymlinksInPath().standardizedFileURL.path != bootstrapPath {
                try bootstrap.restoreRecoverySnapshot(from: snapshot, resetRemoteContent: true)
            }
            try bootstrap.verifyCompleteRecoveryState()
            return bootstrap
        }.value
        userDefaults.set(archiveRoot.path, forKey: "lastProviderRecoveryPath")
        return fallback
    }

    /// Listen for the "Sync Now" action the File Provider extension exposes in
    /// Finder. The extension can't sync by itself, so it posts a Darwin
    /// notification and we do the work here.
    private func observeSyncNowRequests() {
        syncNowObserver = DarwinNotification.addObserver(
            for: BundleIdentifiers.syncNowRequestNotification
        ) { [weak self] in
            Task { @MainActor in
                self?.handleSyncNowRequest()
            }
        }
    }

    private func handleSyncNowRequest() {
        // The extension posts a second time after cold-launching the app, and
        // Finder lets the user invoke the action repeatedly. Collapse those.
        let now = Date()
        if let last = lastSyncNowRequest, now.timeIntervalSince(last) < 5 {
            logger.debug("Ignoring duplicate Sync Now request")
            return
        }
        lastSyncNowRequest = now

        if case .syncing = syncStatus {
            logger.info("Sync Now requested while a sync is already running — ignoring")
            return
        }

        logger.info("Sync Now requested from Finder")
        guard !sessionWork.isTransitioning else { return }
        requestedSyncTask?.cancel()
        requestedSyncTask = Task { await performRequestedSync() }
    }

    /// Run a user-requested sync, tolerating the case where the app was
    /// cold-launched by the request itself and is still restoring its session.
    private func performRequestedSync() async {
        let lease = sessionWork.lease
        for attempt in 0..<10 {
            guard sessionWork.isCurrent(lease) else { return }
            if currentSite != nil, currentToken != nil, syncEngine != nil {
                await syncAll()
                return
            }
            if attempt == 0 {
                logger.info("Sync Now: waiting for the session to finish loading")
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        logger.warning("Sync Now: no active session after waiting — skipping")
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

        guard !isDatabaseTransitioning, !sessionExpired,
              currentSite != nil, currentToken != nil, syncEngine != nil else {
            lastAppliedSyncInterval = -1
            return
        }

        let rawInterval = userDefaults.double(forKey: Self.syncIntervalMinutesKey)
        // Clamp to a sane range so a corrupt or maliciously edited preference can't
        // overflow UInt64 in the nanosecond conversion. Zero or less means "off";
        // any other value is kept between 1 minute and 24 hours.
        let intervalMinutes = rawInterval > 0 ? min(max(rawInterval, 1), 24 * 60) : 0
        lastAppliedSyncInterval = intervalMinutes
        // Write the clamped value back so the defaults observer sees a match and
        // doesn't restart this timer again on every unrelated defaults write.
        if intervalMinutes != rawInterval {
            userDefaults.set(intervalMinutes, forKey: Self.syncIntervalMinutesKey)
        }
        guard intervalMinutes > 0 else { return }

        let intervalNanoseconds = UInt64(intervalMinutes * 60 * 1_000_000_000)
        let lease = sessionWork.lease
        automaticSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: intervalNanoseconds)
                } catch {
                    break
                }

                guard let self, self.sessionWork.isCurrent(lease) else { return }
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
            logger.warning("Failed to resolve File Provider root URL: \(DiagnosticFailure(error).summary, privacy: .public)")
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

    // MARK: Finder companion

    func companionRootURL() async -> URL? {
        guard let site = currentSite else { return nil }
        return await fileProviderRootURL(for: site)
    }

    func finishOnboarding() {
        guard let site = currentSite, let token = currentToken, let database else { return }
        activateAuthenticatedSession(site: site, token: token, accounts: accounts,
                                     database: database, triggerLaunchSync: false)
    }

    func companionNodes(for course: MoodleCourse) -> [CompanionNode] {
        guard let database, let site = currentSite, site.id == course.siteID,
              let items = try? database.fetchItems(courseID: course.id, siteID: site.id) else { return [] }
        if let outline = try? database.fetchCourseOutline(courseID: course.id, siteID: site.id) {
            return outline.sections.filter(\.visible).sorted { $0.sectionNumber < $1.sectionNumber }.map { section in
                let sectionID = "section-\(site.id)-\(course.id)-\(section.id)"
                let modules = section.modules.filter(\.visible).map { module in
                    let matches = items.filter { $0.remoteID == module.id && !$0.isLocal }
                    let files = matches.filter { !$0.isDirectory }.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
                    let children = files.map { CompanionNode($0.filename, destination: .item($0.id)) }
                    if children.count == 1, module.type == "resource" { return children[0] }
                    var components = URLComponents(url: site.baseURL.appendingPathComponent("mod/\(module.type)/view.php"), resolvingAgainstBaseURL: false)
                    components?.queryItems = [URLQueryItem(name: "id", value: String(module.id))]
                    let destination: CompanionNode.Destination = matches.first(where: \.isDirectory)
                        .map { .item($0.id) } ?? components?.url.map { .web($0) } ?? .none
                    return CompanionNode(module.name, destination: destination, children: children)
                }
                return CompanionNode(section.name, destination: .item(sectionID), children: modules)
            }
        }
        let root = "course-\(course.siteID)-\(course.id)"
        let byParent = Dictionary(grouping: items, by: \.parentID)
        func nodes(under id: String, visited: Set<String>) -> [CompanionNode] {
            guard !visited.contains(id) else { return [] }
            let visited = visited.union([id])
            return (byParent[id] ?? []).sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }.map {
                CompanionNode($0.filename, destination: .item($0.id), children: $0.isDirectory ? nodes(under: $0.id, visited: visited) : [])
            }
        }
        return nodes(under: root, visited: [])
    }

    func openCompanionItem(_ id: String) async {
        guard let site = currentSite, let item = try? database?.fetchItem(id: id), item.siteID == site.id else { return }
        let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier(BundleIdentifiers.fileProviderDomainID(siteID: site.id)), displayName: site.displayName)
        guard let manager = NSFileProviderManager(for: domain) else { return }
        let result = await Self.userVisibleFileProviderURL(using: manager, for: NSFileProviderItemIdentifier(id))
        if let url = result.url {
            NSWorkspace.shared.open(url)
        } else {
            errorMessage = result.error?.localizedDescription ?? "This file is not available in Finder yet. Try syncing the course."
        }
    }

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
            logger.warning("No NSFileProviderManager for domain \(domainID, privacy: .private) — domain may not be registered")
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
                    logger.warning("File Provider signal retry failed: \(DiagnosticFailure(error).summary, privacy: .public)")
                }
            } catch {
                logger.error("Failed to signal File Provider: \(DiagnosticFailure(error).summary, privacy: .public)")
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
        let lease = sessionWork.lease
        guard let rootURL = await fileProviderRootURL(for: site) else {
            logger.info("Cannot pin to sidebar: File Provider root URL not available yet")
            return
        }
        guard sessionWork.isCurrent(lease) else { return }

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
                log.warning("Could not pin to Finder sidebar: \(DiagnosticFailure(error).summary, privacy: .public)")
            }
        }
    }
}

/// Resumes a continuation at most once, so racing callbacks (for example a
/// termination handler and a timeout) can both try without a double resume.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
