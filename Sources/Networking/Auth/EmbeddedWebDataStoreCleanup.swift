import Foundation
import WebKit
import OSLog
import SharedDomain

/// One owner per host process protects all live attempts and their retry queue.
@MainActor
final class EmbeddedWebDataStoreCleanup {
    static let shared = EmbeddedWebDataStoreCleanup(
        storageURL: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "es.amodrono.findle", isDirectory: true)
            .appendingPathComponent("EmbeddedSSOStores.json"),
        removeStore: { try await EmbeddedWebDataStoreCleanup.removePersistentStore($0) }
    )

    static func removePersistentStore(_ identifier: UUID) async throws {
        // Startup cleanup can be the process's first WebKit call. The static
        // removal API does not initialize WebKit's main run loop on all OS
        // versions; bootstrap with an ephemeral store before dispatching it.
        // This creates no persistent store or web view and loads no content.
        _ = WKWebsiteDataStore.nonPersistent()
        do { try await WKWebsiteDataStore.remove(forIdentifier: identifier) }
        catch {
            // A prior successful removal may have crashed before queue commit.
            // Confirm absence through WebKit, without matching error messages.
            let remaining = await WKWebsiteDataStore.allDataStoreIdentifiers
            guard !remaining.contains(identifier) else { throw error }
        }
    }

    private struct Archive: Codable {
        let version: Int
        let pending: [UUID]
    }

    private let storageURL: URL
    private let maximumEntries: Int
    private let removeStore: @MainActor (UUID) async throws -> Void
    private let logger = Logger(subsystem: "es.amodrono.findle.networking", category: "EmbeddedSSOCleanup")
    private(set) var pendingIdentifiers: [UUID] = []
    private(set) var liveIdentifiers: Set<UUID> = []
    private var removals: [UUID: Task<Void, Never>] = [:]
    private var loadFailed = false

    init(storageURL: URL, maximumEntries: Int = 32,
         removeStore: @escaping @MainActor (UUID) async throws -> Void) {
        self.storageURL = storageURL
        self.maximumEntries = maximumEntries
        self.removeStore = removeStore
        loadArchive()
    }

    /// Persist before constructing a store so a crashed/abandoned attempt can
    /// be retired on the next launch. Full or unwritable queues stop admission.
    func registerAttempt(identifier: UUID = UUID()) throws -> UUID {
        if loadFailed { loadArchive() }
        guard !loadFailed, pendingIdentifiers.count < maximumEntries,
              !pendingIdentifiers.contains(identifier), !liveIdentifiers.contains(identifier) else {
            throw FindleError.ssoSessionStartFailed(
                detail: "Previous sign-in data could not be cleared. Try signing in again shortly."
            )
        }
        let updated = pendingIdentifiers + [identifier]
        do { try persist(updated) }
        catch {
            logger.error("Cannot retain sign-in cleanup: \(DiagnosticFailure(error).summary, privacy: .public)")
            throw FindleError.ssoSessionStartFailed(
                detail: "Sign-in cleanup could not be saved. Check available disk space and try again."
            )
        }
        pendingIdentifiers = updated
        liveIdentifiers.insert(identifier)
        return identifier
    }

    /// Only the actual web-view lifetime ends an attempt's protection.
    func viewWasReleased(identifier: UUID) {
        liveIdentifiers.remove(identifier)
        scheduleRemoval(identifier)
    }

    /// Bounded per configure call; never poll WebKit or remove a live store.
    func retryPending(maximum: Int = 4) {
        if loadFailed { loadArchive() }
        guard !loadFailed else { return }
        let candidates = pendingIdentifiers.filter {
            !liveIdentifiers.contains($0) && removals[$0] == nil
        }
        for identifier in candidates.prefix(max(0, maximum)) { scheduleRemoval(identifier) }
    }

    /// Await already-requested cleanup; useful for controlled lifecycle tests.
    func waitForScheduledRemovals() async {
        let scheduled = Array(removals.values)
        for task in scheduled { await task.value }
    }

    private func scheduleRemoval(_ identifier: UUID) {
        guard pendingIdentifiers.contains(identifier), !liveIdentifiers.contains(identifier),
              removals[identifier] == nil else { return }
        removals[identifier] = Task { [self] in
            do {
                try await removeStore(identifier)
                let updated = pendingIdentifiers.filter { $0 != identifier }
                try persist(updated)
                pendingIdentifiers = updated
            } catch {
                // Keep the ID on disk and in memory, including a failure to
                // persist successful removal. Repeating removal is harmless.
                logger.error("Sign-in cleanup will be retried: \(DiagnosticFailure(error).summary, privacy: .public)")
            }
            removals[identifier] = nil
        }
    }

    private func loadArchive() {
        do {
            let file: FileHandle
            do { file = try FileHandle(forReadingFrom: storageURL) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                pendingIdentifiers = []
                loadFailed = false
                return
            }
            defer { try? file.close() }
            let data = try file.read(upToCount: 32_769) ?? Data()
            guard data.count <= 32_768 else { throw CocoaError(.fileReadCorruptFile) }
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.version == 1, Set(archive.pending).count == archive.pending.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            pendingIdentifiers = archive.pending
            loadFailed = false
        } catch {
            loadFailed = true
            logger.error("Cannot read pending sign-in cleanup: \(DiagnosticFailure(error).summary, privacy: .public)")
        }
    }

    private func persist(_ identifiers: [UUID]) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(Archive(version: 1, pending: identifiers))
        try data.write(to: storageURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }
}

/// Main-actor WebKit views are released on the UI actor. Scheduling from deinit
/// waits until the complete WKWebView deallocation has returned before removal.
@MainActor
final class EmbeddedAuthenticationWebView: WKWebView {
    private let storeIdentifier: UUID
    private let cleanup: EmbeddedWebDataStoreCleanup

    init(configuration: WKWebViewConfiguration, storeIdentifier: UUID, cleanup: EmbeddedWebDataStoreCleanup) {
        self.storeIdentifier = storeIdentifier
        self.cleanup = cleanup
        super.init(frame: .zero, configuration: configuration)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    deinit {
        let identifier = storeIdentifier
        let cleanup = cleanup
        Task { @MainActor in cleanup.viewWasReleased(identifier: identifier) }
    }
}
