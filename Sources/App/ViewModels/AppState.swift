import Foundation
import SwiftUI
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
    @Published var syncStatus: SyncStatus = .idle
    @Published var lastSyncDate: Date?
    @Published var errorMessage: String?

    private let moodleClient = MoodleClient()
    private var database: Database?
    private var syncEngine: SyncEngine?
    private var currentToken: AuthToken?
    private var currentSite: MoodleSite?
    private let logger = Logger(subsystem: "com.foodle.app", category: "AppState")

    enum AppScreen {
        case onboarding
        case courses
        case settings
        case diagnostics
    }

    enum SyncStatus: Equatable {
        case idle
        case syncing(progress: Double)
        case completed
        case error(String)
    }

    init() {
        do {
            self.database = try Database()
            loadAccounts()
        } catch {
            logger.error("Failed to initialize database: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Account Management

    func loadAccounts() {
        guard let db = database else { return }
        do {
            accounts = try db.fetchAccounts()
            if let account = accounts.first, account.state.isConnected {
                if let site = try db.fetchSite(id: account.siteID) {
                    currentSite = site
                    if let tokenString = try KeychainManager.shared.retrieveToken(forAccount: account.id) {
                        currentToken = AuthToken(token: tokenString)
                        Task {
                            await loadCourses()
                        }
                        currentScreen = .courses
                    }
                }
            }
        } catch {
            logger.error("Failed to load accounts: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Onboarding

    func validateSite(urlString: String) async throws -> MoodleSite {
        guard let url = URL(string: urlString) else {
            throw FoodleError.siteUnreachable(url: URL(string: "invalid")!)
        }
        let site = try await moodleClient.validateSite(url: url)
        return site
    }

    func signIn(site: MoodleSite, username: String, password: String) async throws {
        let token = try await moodleClient.authenticate(site: site, username: username, password: password)
        let user = try await moodleClient.fetchUserInfo(site: site, token: token)

        // Save to database
        guard let db = database else { throw FoodleError.databaseError(detail: "Database not available") }
        try db.saveSite(site)

        let account = Account(
            siteID: site.id,
            userID: user.id,
            state: .authenticated(userID: user.id)
        )
        try db.saveAccount(account)

        // Store token in Keychain
        try KeychainManager.shared.storeToken(token.token, forAccount: account.id)

        // Set up File Provider domain
        try await setupFileProviderDomain(site: site)

        // Update state
        currentSite = site
        currentToken = token
        accounts = [account]
        currentScreen = .courses

        // Initialize sync engine and load courses
        syncEngine = SyncEngine(provider: moodleClient, database: db)
        await loadCourses()
    }

    // MARK: - File Provider Domain

    private func setupFileProviderDomain(site: MoodleSite) async throws {
        let domainID = NSFileProviderDomainIdentifier("com.foodle.domain.\(site.id)")
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)

        do {
            try await NSFileProviderManager.add(domain)
            logger.info("File Provider domain added: \(site.displayName, privacy: .public)")
        } catch {
            logger.error("Failed to add File Provider domain: \(error.localizedDescription, privacy: .public)")
            throw FoodleError.domainSetupFailed(detail: error.localizedDescription)
        }
    }

    // MARK: - Course Management

    func loadCourses() async {
        guard let site = currentSite, let token = currentToken else { return }
        guard let account = accounts.first else { return }

        do {
            let remoteCourses = try await moodleClient.fetchCourses(
                site: site,
                token: token,
                userID: account.userID ?? 0
            )
            try database?.saveCourses(remoteCourses)
            courses = remoteCourses
            logger.info("Loaded \(remoteCourses.count) courses")
        } catch {
            logger.error("Failed to load courses: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Sync

    func syncAll() async {
        guard let site = currentSite, let token = currentToken, let engine = syncEngine else { return }

        syncStatus = .syncing(progress: 0)

        await engine.syncAllCourses(site: site, token: token, courses: courses)

        syncStatus = .completed
        lastSyncDate = Date()

        // Signal the File Provider to refresh
        signalFileProviderChanges()
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
        let domainID = NSFileProviderDomainIdentifier("com.foodle.domain.\(site.id)")
        let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)

        NSFileProviderManager(for: domain)?.signalEnumerator(for: .rootContainer) { error in
            if let error = error {
                self.logger.error("Failed to signal File Provider: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Logout

    func logout() async {
        guard let account = accounts.first else { return }

        // Remove File Provider domain
        if let site = currentSite {
            let domainID = NSFileProviderDomainIdentifier("com.foodle.domain.\(site.id)")
            let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
            try? await NSFileProviderManager.remove(domain)
        }

        // Clear Keychain
        try? KeychainManager.shared.deleteToken(forAccount: account.id)

        // Clear database
        try? database?.deleteAllData()

        // Reset state
        accounts = []
        courses = []
        currentSite = nil
        currentToken = nil
        syncEngine = nil
        lastSyncDate = nil
        currentScreen = .onboarding
    }

    // MARK: - Diagnostics

    func rebuildIndex() async {
        try? database?.rebuildIndex()
        await syncAll()
    }

    func resetProvider() async {
        if let site = currentSite {
            let domainID = NSFileProviderDomainIdentifier("com.foodle.domain.\(site.id)")
            let domain = NSFileProviderDomain(identifier: domainID, displayName: site.displayName)
            try? await NSFileProviderManager.remove(domain)
            try? await setupFileProviderDomain(site: site)
        }
    }
}
