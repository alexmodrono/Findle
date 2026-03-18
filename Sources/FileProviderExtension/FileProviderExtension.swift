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

    /// Extract the site ID from the domain identifier (format: `<prefix>.domain.<siteID>`).
    var siteID: String? {
        let domainPrefix = BundleIdentifiers.prefix + ".domain."
        let raw = domain.identifier.rawValue
        guard raw.hasPrefix(domainPrefix) else { return nil }
        return String(raw.dropFirst(domainPrefix.count))
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

        // Local items have no remote — if their content is missing, report an error.
        if localItem.isLocal {
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            return progress
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

    // MARK: - Local Content Storage

    /// Directory for storing user-created local file content.
    private func localContentDirectory() throws -> URL {
        let stateDir = try Self.stateDirectoryURL(for: domain)
        let dir = stateDir
            .appendingPathComponent(".FoodleState", isDirectory: true)
            .appendingPathComponent("LocalContent", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns the on-disk URL for a local item's content.
    private func localContentURL(itemID: String) throws -> URL {
        try localContentDirectory().appendingPathComponent(itemID)
    }

    // MARK: - Modification

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard let db = database, let siteID else {
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
            return Progress()
        }

        // Determine the parent.  Items at the root have parentID = nil.
        let parentID: String?
        if itemTemplate.parentItemIdentifier == .rootContainer {
            parentID = nil
        } else {
            parentID = itemTemplate.parentItemIdentifier.rawValue
        }

        // Infer courseID from parent item (local items inherit their parent's course).
        let courseID: Int
        if let parentID, let parentItem = try? db.fetchItem(id: parentID) {
            courseID = parentItem.courseID
        } else {
            courseID = 0 // Root-level local item
        }

        let itemID = "local-\(UUID().uuidString)"
        let now = Date()
        let isDirectory = itemTemplate.contentType == .folder

        var localItem = LocalItem(
            id: itemID,
            parentID: parentID,
            siteID: siteID,
            courseID: courseID,
            remoteID: 0,
            filename: itemTemplate.filename,
            isDirectory: isDirectory,
            contentType: isDirectory ? nil : itemTemplate.contentType?.preferredMIMEType,
            fileSize: (itemTemplate.documentSize ?? nil)?.int64Value ?? 0,
            creationDate: now,
            modificationDate: now,
            syncState: .materialized,
            isLocal: true
        )

        do {
            // Persist file content for non-directory items.
            if !isDirectory, let contentURL = url {
                let dest = try localContentURL(itemID: itemID)
                try FileManager.default.copyItem(at: contentURL, to: dest)
                localItem.localPath = dest.path
            }

            try db.saveItems([localItem])
            completionHandler(FileProviderItem(localItem: localItem), [], false, nil)
        } catch {
            logger.error("createItem failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, [], false, error)
        }

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
        guard let db = database else {
            completionHandler(nil, [], false, NSFileProviderError(.notAuthenticated))
            return Progress()
        }

        guard var localItem = try? db.fetchItem(id: item.itemIdentifier.rawValue) else {
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress()
        }

        // Only allow modifications to local items.
        guard localItem.isLocal else {
            completionHandler(nil, [], false, NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            return Progress()
        }

        do {
            var newFilename = localItem.filename
            var newParentID = localItem.parentID
            var newLocalPath = localItem.localPath
            var newFileSize = localItem.fileSize
            var newTagData = localItem.tagData

            if changedFields.contains(.filename) {
                newFilename = item.filename
            }
            if changedFields.contains(.parentItemIdentifier) {
                newParentID = item.parentItemIdentifier == .rootContainer ? nil : item.parentItemIdentifier.rawValue
            }
            if changedFields.contains(.contents), let newContents {
                let dest = try localContentURL(itemID: localItem.id)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: newContents, to: dest)
                newLocalPath = dest.path
                let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
                newFileSize = (attrs?[.size] as? Int64) ?? 0
            }
            if changedFields.contains(.tagData) {
                newTagData = item.tagData ?? nil
            }

            let updated = LocalItem(
                id: localItem.id,
                parentID: newParentID,
                siteID: localItem.siteID,
                courseID: localItem.courseID,
                remoteID: localItem.remoteID,
                filename: newFilename,
                isDirectory: localItem.isDirectory,
                contentType: localItem.contentType,
                fileSize: newFileSize,
                creationDate: localItem.creationDate,
                modificationDate: Date(),
                syncState: localItem.syncState,
                isPinned: localItem.isPinned,
                localPath: newLocalPath,
                remoteURL: localItem.remoteURL,
                contentVersion: "\(Date().timeIntervalSince1970)",
                tagData: newTagData,
                isLocal: true
            )

            try db.saveItems([updated])
            completionHandler(FileProviderItem(localItem: updated), [], false, nil)
        } catch {
            logger.error("modifyItem failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(nil, [], false, error)
        }

        return Progress()
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        guard let db = database else {
            completionHandler(NSFileProviderError(.notAuthenticated))
            return Progress()
        }

        guard let localItem = try? db.fetchItem(id: identifier.rawValue) else {
            completionHandler(NSFileProviderError(.noSuchItem))
            return Progress()
        }

        // Only allow deletion of local items.
        guard localItem.isLocal else {
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
            return Progress()
        }

        do {
            // Remove stored content.
            if let path = localItem.localPath {
                try? FileManager.default.removeItem(atPath: path)
            }
            try db.deleteItemAndChildren(id: localItem.id)
            completionHandler(nil)
        } catch {
            logger.error("deleteItem failed: \(error.localizedDescription, privacy: .public)")
            completionHandler(error)
        }

        return Progress()
    }
}
