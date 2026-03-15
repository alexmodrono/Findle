import Foundation
import SwiftUI
import AuthenticationServices
import AppKit
import CoreSpotlight
import SharedDomain
import FoodleNetworking
import FoodlePersistence
import FoodleSyncEngine
import FileProvider
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

    private let moodleClient = MoodleClient()
    private var database: Database?
    private var databaseSecurityScopedURL: URL?
    private(set) var syncEngine: SyncEngine?
    private(set) var currentToken: AuthToken?
    private(set) var currentSite: MoodleSite?
    private var activeWebAuthSession: WebAuthSession?
    private var isLoadingCourses = false
    private var validatedSitesByURL: [String: MoodleSite] = [:]
    private var automaticSyncTask: Task<Void, Never>?
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

    private static let syncOnLaunchKey = "syncOnLaunch"
    private static let syncIntervalMinutesKey = "syncIntervalMinutes"
    private static let currentSiteIDKey = "currentSiteID"

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

    private struct SharedDatabaseLocation {
        let securityScopedDirectoryURL: URL
        let databaseURL: URL
    }

    private func configureInitialDatabase() throws {
        if let siteID = userDefaults.string(forKey: Self.currentSiteIDKey),
           let sharedDatabase = try openSharedDatabase(siteID: siteID, seedFrom: nil) {
            database = sharedDatabase
        } else {
            database = try Database()
        }
    }

    private func openSharedDatabase(siteID: String, seedFrom sourceDatabase: Database?) throws -> Database? {
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

    private func sharedDatabaseLocation(siteID: String) throws -> SharedDatabaseLocation? {
        let domainID = NSFileProviderDomainIdentifier("es.amodrono.foodle.domain.\(siteID)")
        let domain = NSFileProviderDomain(identifier: domainID, displayName: siteID)
        guard let manager = NSFileProviderManager(for: domain) else { return nil }

        guard #available(macOS 15.0, *) else { return nil }
        let storageRootURL = try manager.stateDirectoryURL()

        let databaseURL = storageRootURL
            .appendingPathComponent(".FoodleState", isDirectory: true)
            .appendingPathComponent("Foodle", isDirectory: true)
            .appendingPathComponent("foodle.db")

        return SharedDatabaseLocation(
            securityScopedDirectoryURL: storageRootURL,
            databaseURL: databaseURL
        )
    }

    private func sharedDatabaseNeedsSeeding(siteID: String, databaseURL: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return true }

        let sharedDatabase = try Database(path: databaseURL.path)
        let hasSite = try sharedDatabase.fetchSite(id: siteID) != nil
        let hasConnectedAccount = try sharedDatabase.fetchAccounts().contains {
            $0.siteID == siteID && $0.state.isConnected
        }

        return !(hasSite && hasConnectedAccount)
    }

    private func seedSharedDatabase(from sourceDatabase: Database, siteID: String, destinationURL: URL) throws {
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let sharedDatabase = try Database(path: destinationURL.path)
        try sharedDatabase.deleteAllData()

        if let site = try sourceDatabase.fetchSite(id: siteID) {
            try sharedDatabase.saveSite(site)
        }

        let siteAccounts = try sourceDatabase.fetchAccounts().filter { $0.siteID == siteID }
        for account in siteAccounts {
            try sharedDatabase.saveAccount(account)
        }

        let courses = try sourceDatabase.fetchCourses(siteID: siteID)
        if !courses.isEmpty {
            try sharedDatabase.saveCourses(courses)
        }

        let items = try sourceDatabase.fetchAllItems(siteID: siteID)
        if !items.isEmpty {
            try sharedDatabase.saveItems(items)
        }

        let cursors = try sourceDatabase.fetchAllSyncCursors(siteID: siteID)
        for cursor in cursors {
            try sharedDatabase.saveSyncCursor(cursor)
        }

        logger.info("Seeded File Provider state database for site \(siteID, privacy: .public)")
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
        try await setupFileProviderDomain(site: site)
        if let sharedDatabase = try openSharedDatabase(siteID: site.id, seedFrom: db) {
            database = sharedDatabase
        }
        await resolveFileProviderAuthentication(for: site)
        await pinToFinderSidebar(site: site)

        // Store site/token for later activation without switching screens
        currentSite = site
        currentToken = token
    }

    /// Activate the sync engine and load courses without changing screens.
    /// Called during onboarding's setup step so the Airlock flow can finish
    /// before the workspace appears.
    func activateAfterOnboarding() {
        guard let site = currentSite, let token = currentToken, let db = database else { return }
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
        do {
            try await addFileProviderDomain(site: site)
        } catch {
            logger.error("File Provider domain setup failed on relaunch: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func addFileProviderDomain(site: MoodleSite) async throws {
        let domainID = NSFileProviderDomainIdentifier("es.amodrono.foodle.domain.\(site.id)")
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
        domain.isHidden = false

        do {
            try await NSFileProviderManager.add(domain)
            logger.info("File Provider domain added: \(site.displayName, privacy: .public)")
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
            logger.info("File Provider domain already exists: \(site.displayName, privacy: .public)")
        } catch let error as NSError {
            logger.error("Failed to add File Provider domain: \(error.localizedDescription, privacy: .public) [\(error.domain, privacy: .public):\(error.code)]")
            throw FoodleError.domainSetupFailed(detail: error.localizedDescription)
        }
    }

    private func removeAllFileProviderDomains() async {
        do {
            let domainPairs: [(id: String, name: String)] = try await withCheckedThrowingContinuation { continuation in
                NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                    if let error { continuation.resume(throwing: error) }
                    else {
                        let pairs = domains.map { (id: $0.identifier.rawValue, name: $0.displayName) }
                        continuation.resume(returning: pairs)
                    }
                }
            }
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
            logger.info("Loaded \(self.courses.count) courses")
        } catch {
            logger.error("Failed to load courses: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    func reloadCourseTags() {
        guard let db = database, let site = currentSite else { return }
        courseTags = (try? db.fetchAllCourseTags(siteID: site.id)) ?? [:]
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

        syncStatus = .syncing(progress: 0)

        let enabledCourses = courses.filter(\.isSyncEnabled)
        await engine.syncAllCourses(site: site, token: token, courses: enabledCourses)

        syncStatus = .completed
        lastSyncDate = Date()

        // Signal the File Provider to refresh
        signalFileProviderChanges()

        // Update Spotlight index
        indexForSpotlight()
    }

    func syncCourse(_ course: MoodleCourse) async {
        guard let site = currentSite, let token = currentToken, let engine = syncEngine else { return }

        syncStatus = .syncing(progress: 0)

        do {
            try await engine.syncCourse(site: site, token: token, course: course)
            syncStatus = .completed
            lastSyncDate = Date()
            signalFileProviderChanges()
        } catch {
            syncStatus = .error(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    private func signalFileProviderChanges() {
        guard let site = currentSite else { return }
        signalFileProviderChanges(for: site)
    }

    private func signalFileProviderChanges(for site: MoodleSite) {
        let domainID = NSFileProviderDomainIdentifier("es.amodrono.foodle.domain.\(site.id)")
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)

        guard let manager = NSFileProviderManager(for: domain) else {
            logger.warning("No NSFileProviderManager for domain \(domainID.rawValue, privacy: .public) — domain may not be registered")
            return
        }
        let identifiers: [NSFileProviderItemIdentifier] = [.workingSet, .rootContainer]
        for identifier in identifiers {
            manager.signalEnumerator(for: identifier) { [weak self] error in
                guard let error = error as? NSError else { return }
                if error.domain == NSFileProviderErrorDomain && error.code == -2001 {
                    self?.logger.info("File Provider not ready yet, will retry signal in 3s")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        manager.signalEnumerator(for: identifier) { retryError in
                            if let retryError = retryError as? NSError {
                                self?.logger.warning("File Provider signal retry failed: \(retryError.localizedDescription, privacy: .public)")
                            }
                        }
                    }
                } else {
                    self?.logger.error("Failed to signal File Provider: \(error.localizedDescription, privacy: .public) [\(error.domain, privacy: .public):\(error.code)]")
                }
            }
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
        let domainID = NSFileProviderDomainIdentifier("es.amodrono.foodle.domain.\(site.id)")
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
            let signalError: Error? = await withCheckedContinuation { continuation in
                manager.signalErrorResolved(authError) { error in
                    continuation.resume(returning: error)
                }
            }

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
            let domainID = NSFileProviderDomainIdentifier("es.amodrono.foodle.domain.\(site.id)")
            let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
            try? await NSFileProviderManager.remove(domain)
        }

        // Clear Spotlight index
        SpotlightIndexer.shared.removeAllItems()

        // Clear Keychain
        try? KeychainManager.shared.deleteToken(forAccount: account.id)

        // Clear database before revoking security-scoped access
        try? database?.deleteAllData()
        if let bootstrapDatabase = try? Database() {
            try? bootstrapDatabase.deleteAllData()
        }
        database = nil
        databaseSecurityScopedURL?.stopAccessingSecurityScopedResource()
        databaseSecurityScopedURL = nil
        database = try? Database()
        userDefaults.removeObject(forKey: Self.currentSiteIDKey)

        // Reset state
        accounts = []
        sites = []
        courses = []
        courseTags = [:]
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

        NSWorkspace.shared.activateFileViewerSelecting([targetURL])
    }

    func resetProvider() async {
        guard let site = currentSite else { return }

        if let sourceDatabase = database {
            try? snapshotCurrentDataToBootstrap(from: sourceDatabase, siteID: site.id)
        }

        let domainID = NSFileProviderDomainIdentifier("es.amodrono.foodle.domain.\(site.id)")
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
        try? await NSFileProviderManager.remove(domain)
        try? await setupFileProviderDomain(site: site)

        // Allow fileproviderd time to initialize the new extension instance
        // before attempting to access the state directory or signal auth.
        try? await Task.sleep(for: .seconds(2))

        let bootstrapDatabase = try? Database()
        if let bootstrapDatabase,
           let sharedDatabase = try? openSharedDatabase(siteID: site.id, seedFrom: bootstrapDatabase) {
            database = sharedDatabase
            if let token = currentToken {
                currentSite = site
                currentToken = token
                sites = [site]
                syncEngine = SyncEngine(provider: moodleClient, database: sharedDatabase)

                do {
                    courses = try sharedDatabase.fetchCourses(siteID: site.id)
                    reloadCourseTags()
                } catch {
                    logger.error("Failed to load cached courses after reset: \(error.localizedDescription, privacy: .public)")
                }
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
            if let sharedDatabase = try openSharedDatabase(siteID: site.id, seedFrom: database) {
                activeDatabase = sharedDatabase
                self.database = sharedDatabase
            } else {
                activeDatabase = database
            }
        } catch {
            logger.error("Failed to adopt File Provider database: \(error.localizedDescription, privacy: .public)")
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
            await self.ensureFileProviderDomain(site: site)
            try Task.checkCancellation()
            await self.resolveFileProviderAuthentication(for: site)
            try Task.checkCancellation()
            await self.loadCourses()
            try Task.checkCancellation()
            if triggerLaunchSync && self.userDefaults.bool(forKey: Self.syncOnLaunchKey) {
                await self.syncAll()
            }
            try Task.checkCancellation()
            self.refreshAutomaticSyncSchedule()
        }
    }

    private func snapshotCurrentDataToBootstrap(from sourceDatabase: Database, siteID: String) throws {
        let bootstrapDatabase = try Database()
        try bootstrapDatabase.deleteAllData()

        if let site = try sourceDatabase.fetchSite(id: siteID) {
            try bootstrapDatabase.saveSite(site)
        }

        let siteAccounts = try sourceDatabase.fetchAccounts().filter { $0.siteID == siteID }
        for account in siteAccounts {
            try bootstrapDatabase.saveAccount(account)
        }

        let courses = try sourceDatabase.fetchCourses(siteID: siteID)
        if !courses.isEmpty {
            try bootstrapDatabase.saveCourses(courses)
        }

        let items = try sourceDatabase.fetchAllItems(siteID: siteID)
        if !items.isEmpty {
            try bootstrapDatabase.saveItems(items)
        }

        let cursors = try sourceDatabase.fetchAllSyncCursors(siteID: siteID)
        for cursor in cursors {
            try bootstrapDatabase.saveSyncCursor(cursor)
        }
    }

    private func observeSyncSettings() {
        syncSettingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAutomaticSyncSchedule()
            }
        }
    }

    private func refreshAutomaticSyncSchedule() {
        automaticSyncTask?.cancel()
        automaticSyncTask = nil

        guard currentSite != nil, currentToken != nil, syncEngine != nil else { return }

        let intervalMinutes = userDefaults.double(forKey: Self.syncIntervalMinutesKey)
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
        let domainID = NSFileProviderDomainIdentifier("es.amodrono.foodle.domain.\(site.id)")
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
        guard let manager = NSFileProviderManager(for: domain) else { return nil }

        return await withCheckedContinuation { continuation in
            manager.getUserVisibleURL(for: .rootContainer) { url, error in
                if let error {
                    self.logger.warning("Failed to resolve File Provider root URL: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: url)
            }
        }
    }

    // MARK: - Spotlight

    func handleSpotlightActivity(_ activity: NSUserActivity) {
        guard let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
        let prefix = "es.amodrono.foodle."

        if identifier.hasPrefix("\(prefix)course.") {
            // Extract course ID from "es.amodrono.foodle.course.<siteID>.<courseID>"
            let components = identifier.dropFirst("\(prefix)course.".count).split(separator: ".")
            if let courseIDStr = components.last,
               let courseID = Int(courseIDStr),
               let course = courses.first(where: { $0.id == courseID }) {
                Task { await openFileProviderInFinder(selecting: course) }
            }
        } else if identifier.hasPrefix("\(prefix)item.") {
            // Item identifier is "es.amodrono.foodle.item.<itemID>"
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sfltool")
        process.arguments = [
            "add-item",
            "com.apple.LSSharedFileList.FavoriteItems",
            rootURL.absoluteString
        ]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                logger.info("Pinned Findle to Finder sidebar Favorites")
            } else {
                logger.warning("sfltool exited with status \(process.terminationStatus)")
            }
        } catch {
            logger.warning("Could not pin to Finder sidebar: \(error.localizedDescription, privacy: .public)")
        }
    }
}
