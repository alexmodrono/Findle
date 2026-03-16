// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import SharedDomain
import FoodleNetworking
import FoodlePersistence
import OSLog

/// The File Provider extension that exposes Moodle course content in Finder.
/// Uses the replicated extension model for modern macOS cloud-file behavior.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let logger = Logger(subsystem: "es.amodrono.foodle.file-provider", category: "Extension")
    private let stateLock = NSLock()
    private var _database: Database?
    private var databaseSecurityScopedURL: URL?
    private var rootContainerName: String {
        "Findle-\(FileNameSanitizer.sanitize(domain.displayName))"
    }

    /// Extract the site ID from the domain identifier (format: es.amodrono.foodle.domain.<siteID>).
    var siteID: String? {
        let prefix = "es.amodrono.foodle.domain."
        let raw = domain.identifier.rawValue
        guard raw.hasPrefix(prefix) else { return nil }
        return String(raw.dropFirst(prefix.count))
    }

    /// Lazily resolve the database, retrying until the main app has finished seeding it.
    ///
    /// File Provider requests can arrive concurrently, so the resolution path is
    /// serialized to avoid racing on the cached database and security-scoped URL.
    var database: Database? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let _database { return _database }
        return resolveDatabaseLocked()
    }

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()

        logger.info("File Provider extension initialized for domain: \(domain.identifier.rawValue, privacy: .public)")
    }

    private func resolveDatabaseLocked() -> Database? {
        do {
            let stateDirectoryURL = try Self.stateDirectoryURL(for: domain)
            let databaseURL = Self.databaseURL(in: stateDirectoryURL)

            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                return nil
            }

            let didStart = stateDirectoryURL.startAccessingSecurityScopedResource()
            var adoptedScope = false
            defer {
                if didStart && !adoptedScope {
                    stateDirectoryURL.stopAccessingSecurityScopedResource()
                }
            }

            let db = try Database(path: databaseURL.path)
            guard try databaseIsReady(db) else {
                logger.info("Database exists but is not seeded yet for domain: \(self.domain.identifier.rawValue, privacy: .public)")
                return nil
            }

            // Adopt security-scoped access, releasing any previous scope
            databaseSecurityScopedURL?.stopAccessingSecurityScopedResource()
            databaseSecurityScopedURL = didStart ? stateDirectoryURL : nil
            adoptedScope = true
            _database = db
            logger.info("Database resolved for domain: \(self.domain.identifier.rawValue, privacy: .public)")
            return db
        } catch {
            logger.warning("Database resolution failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func databaseIsReady(_ database: Database) throws -> Bool {
        if let siteID, try database.fetchSite(id: siteID) == nil {
            return false
        }

        if let siteID {
            return try database.fetchAccounts().contains {
                $0.siteID == siteID && $0.state.isConnected
            }
        }

        return true
    }

    func invalidate() {
        stateLock.lock()
        defer { stateLock.unlock() }
        databaseSecurityScopedURL?.stopAccessingSecurityScopedResource()
        databaseSecurityScopedURL = nil
        _database = nil
        logger.info("File Provider extension invalidated")
    }

    private static func stateDirectoryURL(for domain: NSFileProviderDomain) throws -> URL {
        guard let manager = NSFileProviderManager(for: domain) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }

        guard #available(macOS 15.0, *) else {
            throw NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError)
        }
        return try manager.stateDirectoryURL()
    }

    private static func databaseURL(in stateDirectoryURL: URL) -> URL {
        stateDirectoryURL
            .appendingPathComponent(".FoodleState", isDirectory: true)
            .appendingPathComponent("Foodle", isDirectory: true)
            .appendingPathComponent("foodle.db")
    }

    // MARK: - Item Lookup

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.debug("Item requested: \(identifier.rawValue, privacy: .public)")

        let progress = Progress(totalUnitCount: 1)

        if identifier == .rootContainer {
            completionHandler(RootContainerItem(filename: rootContainerName), nil)
            progress.completedUnitCount = 1
            return progress
        }

        guard let db = database,
              let localItem = try? db.fetchItem(id: identifier.rawValue) else {
            completionHandler(nil, NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        completionHandler(FileProviderItem(localItem: localItem), nil)
        progress.completedUnitCount = 1
        return progress
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        logger.debug("Enumerator requested for: \(containerItemIdentifier.rawValue, privacy: .public)")

        guard let db = database, isAuthenticated(using: db) else {
            throw NSFileProviderError(.notAuthenticated)
        }

        if containerItemIdentifier == .workingSet {
            return WorkingSetEnumerator(database: db, siteID: siteID)
        }

        return ItemEnumerator(
            containerIdentifier: containerItemIdentifier,
            database: db
        )
    }

    private func isAuthenticated(using database: Database) -> Bool {
        guard let account = try? database.fetchAccounts().last(where: { $0.state.isConnected }) else {
            return false
        }

        return (try? KeychainManager.shared.retrieveToken(forAccount: account.id)) != nil
    }

    // MARK: - Content Fetch (Download/Materialization)

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.info("Fetch contents for: \(itemIdentifier.rawValue, privacy: .public)")

        let progress = Progress(totalUnitCount: 100)

        guard let db = database,
              let localItem = try? db.fetchItem(id: itemIdentifier.rawValue) else {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
        }

        // If already materialized and local path exists, return it
        if localItem.syncState == .materialized, let localPath = localItem.localPath {
            let localURL = URL(fileURLWithPath: localPath)
            if FileManager.default.fileExists(atPath: localPath) {
                completionHandler(localURL, FileProviderItem(localItem: localItem), nil)
                progress.completedUnitCount = 100
                return progress
            }
        }

        do {
            try FileDownloader.startDownload(
                item: localItem,
                database: db,
                progress: progress,
                completionHandler: completionHandler
            )
        } catch {
            completionHandler(nil, nil, error)
        }

        return progress
    }

    // Download logic moved to FileDownloader for Sendable compliance.

    // MARK: - Modification (Read-Only for now)

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        // Moodle content is read-only for now
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        return Progress()
    }
}
