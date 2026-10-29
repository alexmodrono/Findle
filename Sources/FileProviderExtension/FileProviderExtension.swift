// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import SharedDomain
import FindleNetworking
import FindlePersistence
import OSLog

/// The File Provider extension that exposes Moodle course content in Finder.
/// Uses the replicated extension model for modern macOS cloud-file behavior.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    let domain: NSFileProviderDomain
    let logger = Logger(subsystem: "es.amodrono.findle.file-provider", category: "Extension")
    private let stateLock = NSLock()
    private var _database: Database?
    private var databaseSecurityScopedURL: URL?
    /// Name of the folder this domain mounts as under `~/Library/CloudStorage`.
    /// Built from the product name so a Nightly domain for the same Moodle site
    /// can't collide with the release one.
    private var rootContainerName: String {
        "\(BundleIdentifiers.appDisplayName)-\(FileNameSanitizer.sanitize(domain.displayName))"
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

        logger.info("File Provider extension initialized for domain: \(domain.identifier.rawValue, privacy: .private)")
    }

    private func resolveDatabaseLocked() -> Database? {
        var journal: DiagnosticJournal?
        let attemptID = UUID()
        do {
            let stateDirectoryURL = try Self.stateDirectoryURL(for: domain)
            let databaseURL = Self.databaseURL(in: stateDirectoryURL)
            journal = DiagnosticJournal(databasePath: databaseURL.path)

            let didStart = stateDirectoryURL.startAccessingSecurityScopedResource()
            var adoptedScope = false
            defer {
                if didStart && !adoptedScope {
                    stateDirectoryURL.stopAccessingSecurityScopedResource()
                }
            }

            // The state directory may be security-scoped. Checking the file
            // before acquiring that scope can report a false negative and make
            // Finder treat a healthy domain as disconnected.
            guard FileManager.default.fileExists(atPath: databaseURL.path) else {
                return nil
            }

            let db = try Database(path: databaseURL.path)
            guard try db.isSeedComplete(), try databaseIsReady(db) else {
                logger.info("Database exists but is not seeded yet for domain: \(self.domain.identifier.rawValue, privacy: .private)")
                return nil
            }

            // Adopt security-scoped access, releasing any previous scope
            databaseSecurityScopedURL?.stopAccessingSecurityScopedResource()
            databaseSecurityScopedURL = didStart ? stateDirectoryURL : nil
            adoptedScope = true
            _database = db
            let related = (try? journal?.read())?.last(where: { $0.process == .app })?.attemptID
            journal?.record(.init(attemptID: attemptID, relatedAttemptID: related, process: .fileProvider,
                                  operation: .databaseOpen, outcome: .succeeded))
            logger.info("Database resolved for domain: \(self.domain.identifier.rawValue, privacy: .private)")
            return db
        } catch {
            journal?.record(.init(attemptID: attemptID, process: .fileProvider, operation: .databaseOpen,
                                  outcome: .failed, failure: DiagnosticFailure(error)))
            logger.warning("Database resolution failed: \(DiagnosticFailure(error).summary, privacy: .public)")
            return nil
        }
    }

    private func databaseIsReady(_ database: Database) throws -> Bool {
        if let siteID, try database.fetchSite(id: siteID) == nil {
            return false
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
            .appendingPathComponent(".FindleState", isDirectory: true)
            .appendingPathComponent("Findle", isDirectory: true)
            .appendingPathComponent("findle.db")
    }

    // MARK: - Item Lookup

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.debug("Item requested: \(identifier.rawValue, privacy: .private)")

        let progress = Progress(totalUnitCount: 1)

        if identifier == .rootContainer {
            completionHandler(RootContainerItem(filename: rootContainerName), nil)
            progress.completedUnitCount = 1
            return progress
        }

        // Without a database the domain isn't seeded yet, which is transient.
        guard let db = database else {
            completionHandler(nil, NSFileProviderError(.serverUnreachable))
            progress.completedUnitCount = 1
            return progress
        }

        switch lookupItem(id: identifier.rawValue, database: db) {
        case .found(let localItem):
            completionHandler(FileProviderItem(localItem: localItem), nil)
        case .missing:
            completionHandler(nil, NSFileProviderError(.noSuchItem))
        case .failed:
            completionHandler(nil, NSFileProviderError(.serverUnreachable))
        }
        progress.completedUnitCount = 1
        return progress
    }

    /// Result of a row lookup for a File Provider request. Only `.missing` means
    /// the item is gone; a failed query is transient and must not make Finder
    /// drop the item.
    private enum ItemLookup {
        case found(LocalItem)
        case missing
        case failed(Error)
    }

    private func lookupItem(id: String, database: Database) -> ItemLookup {
        do {
            guard let item = try database.fetchItem(id: id), item.siteID == siteID else { return .missing }
            return .found(item)
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .databaseRead, outcome: .failed, failure: DiagnosticFailure(error)))
            logger.error("Item lookup failed for \(id, privacy: .private): \(DiagnosticFailure(error).summary, privacy: .public)")
            return .failed(error)
        }
    }

    // MARK: - Enumeration

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        logger.debug("Enumerator requested for: \(containerItemIdentifier.rawValue, privacy: .private)")

        let db = try ProviderAccess.enumerationDatabase(database, siteID: siteID) {
            try KeychainManager.shared.retrieveToken(forAccount: $0)
        }

        if containerItemIdentifier == .workingSet {
            return WorkingSetEnumerator(database: db, siteID: siteID)
        }

        return ItemEnumerator(
            containerIdentifier: containerItemIdentifier,
            database: db,
            siteID: siteID
        )
    }

    // MARK: - Content Fetch (Download/Materialization)

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        logger.info("Fetch contents for: \(itemIdentifier.rawValue, privacy: .private)")

        let progress = Progress(totalUnitCount: 100)

        guard let db = database else {
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            progress.cancel()
            return progress
        }

        let localItem: LocalItem
        switch lookupItem(id: itemIdentifier.rawValue, database: db) {
        case .found(let item):
            localItem = item
        case .missing:
            completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
            progress.cancel()
            return progress
        case .failed:
            completionHandler(nil, nil, NSFileProviderError(.serverUnreachable))
            progress.cancel()
            return progress
        }

        // User files live in the personal store, which the system must not own.
        // Hand it a copy instead. APFS clones the file, so this is cheap.
        if isUserItem(localItem) {
            guard let localPath = localItem.localPath,
                  FileManager.default.fileExists(atPath: localPath) else {
                completionHandler(nil, nil, NSFileProviderError(.noSuchItem))
                progress.cancel()
                return progress
            }
            do {
                let copyURL = try makeProviderTemporaryCopy(of: URL(fileURLWithPath: localPath))
                completionHandler(copyURL, FileProviderItem(localItem: localItem), nil)
                progress.completedUnitCount = 100
            } catch {
                logger.error("Could not copy personal file for fetch: \(DiagnosticFailure(error).summary, privacy: .public)")
                completionHandler(nil, nil, error)
                progress.cancel()
            }
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
            progress.cancel()
            return progress
        }

        do {
            let providerTemporaryDirectory: URL?
            if #available(macOS 15.0, *),
               let manager = NSFileProviderManager(for: domain) {
                providerTemporaryDirectory = try? manager.temporaryDirectoryURL()
            } else {
                providerTemporaryDirectory = nil
            }
            try FileDownloader.startDownload(
                item: localItem,
                database: db,
                progress: progress,
                temporaryDirectory: providerTemporaryDirectory,
                completionHandler: completionHandler
            )
        } catch {
            progress.cancel()
            completionHandler(nil, nil, error)
        }

        return progress
    }

    // Download logic moved to FileDownloader for Sendable compliance.

    // MARK: - Personal Files

    /// The folder that holds the canonical copy of every user file.
    private var personalFiles: PersonalFileStore {
        PersonalFileStore(rootURL: PersonalFileStore.defaultRootURL())
    }

    /// Display name of the site's folder in the personal files store.
    private func siteName(for siteID: String, database: Database) -> String {
        (try? database.fetchSite(id: siteID))?.displayName ?? domain.displayName
    }

    /// Copies `source` into the provider's temporary directory under a unique name.
    private func makeProviderTemporaryCopy(of source: URL) throws -> URL {
        let base: URL
        if #available(macOS 15.0, *),
           let manager = NSFileProviderManager(for: domain),
           let providerTemporaryDirectory = try? manager.temporaryDirectoryURL() {
            base = providerTemporaryDirectory
        } else {
            base = FileManager.default.temporaryDirectory
        }
        let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copyURL = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copyURL)
        return copyURL
    }

    /// Size in bytes of the file at `url`, or 0 when it can't be read.
    private static func fileSize(at url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64) ?? 0
    }

    /// Renames within one directory. Used for case-only changes, where
    /// `FileManager.moveItem` may refuse because the target already exists.
    private static func renameEntry(at source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Directory for LocalContent/ (legacy storage). Only the orphan sweep still reads it.
    private func localContentDirectory() throws -> URL {
        let stateDir = try Self.stateDirectoryURL(for: domain)
        let dir = stateDir
            .appendingPathComponent(".FindleState", isDirectory: true)
            .appendingPathComponent("LocalContent", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Modification

    /// Whether a non-user sibling (Moodle item or stand-in) in `parentID` already uses `filename`.
    /// `itemID` is excluded so an item never clashes with itself.
    private func hasNonUserSiblingClash(
        filename: String,
        parentID: String?,
        siteID: String,
        excludingID itemID: String?,
        db: Database
    ) throws -> Bool {
        try db.fetchItems(parentID: parentID, siteID: siteID).contains {
            $0.id != itemID && !isUserItem($0) && $0.filename.caseInsensitiveCompare(filename) == .orderedSame
        }
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        guard let db = database, let siteID else {
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
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
        // Any directory accepts new items: user folders, Moodle folders, and stand-ins.
        let courseID: Int
        if let parentID {
            let parentItem: LocalItem
            switch lookupItem(id: parentID, database: db) {
            case .found(let item):
                parentItem = item
            case .missing:
                completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
                return Progress()
            case .failed:
                completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
                return Progress()
            }
            guard isContainer(parentItem) else {
                completionHandler(nil, [], false, NSFileProviderError(.cannotSynchronize))
                return Progress()
            }
            courseID = parentItem.courseID
        } else {
            courseID = 0 // Root-level local item
        }

        // Keep a new item from shadowing a Moodle item or stand-in with the same name.
        let requestedName = itemTemplate.filename
        let clashes: Bool
        do {
            clashes = try hasNonUserSiblingClash(
                filename: requestedName,
                parentID: parentID,
                siteID: siteID,
                excludingID: nil,
                db: db
            )
        } catch {
            logger.error("createItem could not read siblings: \(DiagnosticFailure(error).summary, privacy: .public)")
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            return Progress()
        }
        let filename = clashes ? PersonalFileStore.mineFilename(for: requestedName) : requestedName

        let itemID = "local-\(UUID().uuidString)"
        // Use `conforms(to:)` so app bundles (.app, .pkg) and other directory
        // subtypes are treated as folders. Equality check on `.folder` misses
        // these and they would be saved as flat files with the bundle's
        // documentSize, losing the inner contents.
        let isDirectory = itemTemplate.contentType?.conforms(to: .directory) == true

        let directory: URL
        do {
            directory = try personalFiles.directory(
                forParentID: parentID,
                siteID: siteID,
                siteName: siteName(for: siteID, database: db),
                database: db
            )
        } catch {
            logger.error("createItem could not locate its folder: \(DiagnosticFailure(error).summary, privacy: .public)")
            completionHandler(nil, [], false, error)
            return Progress()
        }

        // Write under a hidden name, stamp the item id, then move into place. Scans
        // skip hidden names, so a half-written item is never imported.
        let finalURL = personalFiles.uniqueURL(for: filename, in: directory)
        let stagingURL = personalFiles.stagingURL(in: directory)
        do {
            if isDirectory {
                if let url {
                    // Packages such as .pages or .app arrive with their contents.
                    try FileManager.default.copyItem(at: url, to: stagingURL)
                } else {
                    try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: false)
                }
            } else if let url {
                try FileManager.default.copyItem(at: url, to: stagingURL)
            } else {
                // A file created without contents still gets an empty file on disk.
                try Data().write(to: stagingURL)
            }
            try PersonalFileStore.setItemID(itemID, at: stagingURL)
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            logger.error("createItem failed to store content: \(DiagnosticFailure(error).summary, privacy: .public)")
            completionHandler(nil, [], false, error)
            return Progress()
        }

        let now = Date()
        let localItem = LocalItem(
            id: itemID,
            parentID: parentID,
            siteID: siteID,
            courseID: courseID,
            remoteID: 0,
            filename: finalURL.lastPathComponent,
            isDirectory: isDirectory,
            contentType: isDirectory ? nil : itemTemplate.contentType?.preferredMIMEType,
            fileSize: isDirectory ? 0 : Self.fileSize(at: finalURL),
            creationDate: now,
            modificationDate: now,
            syncState: .materialized,
            localPath: finalURL.path,
            isLocal: true
        )

        do {
            try db.saveItems([localItem])
            completionHandler(FileProviderItem(localItem: localItem), [], false, nil)
        } catch {
            // Without a row the item would be lost on the next scan, so take it back out.
            try? FileManager.default.removeItem(at: finalURL)
            logger.error("createItem failed to save row: \(DiagnosticFailure(error).summary, privacy: .public)")
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
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
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            return Progress()
        }

        let itemID = item.itemIdentifier.rawValue

        let localItem: LocalItem
        switch lookupItem(id: itemID, database: db) {
        case .found(let item):
            localItem = item
        case .missing:
            completionHandler(nil, [], false, NSFileProviderError(.noSuchItem))
            return Progress()
        case .failed:
            completionHandler(nil, [], false, NSFileProviderError(.serverUnreachable))
            return Progress()
        }

        // User items: full edits allowed (rename, move, content, tags).
        if isUserItem(localItem) {
            do {
                let updated = try updateUserItem(
                    localItem,
                    item: item,
                    changedFields: changedFields,
                    newContents: newContents,
                    db: db
                )
                completionHandler(FileProviderItem(localItem: updated), [], false, nil)
            } catch {
                logger.error("modifyItem failed: \(DiagnosticFailure(error).summary, privacy: .public)")
                completionHandler(nil, [], false, error)
            }
            return Progress()
        }

        do {
            let result = try SyncedItemModification.apply(
                to: localItem,
                changedFields: changedFields,
                tagData: item.tagData ?? nil,
                hasNewContents: newContents != nil,
                siteID: siteID,
                database: db
            )
            completionHandler(result.item, result.stillPendingFields, false, nil)
        } catch let error as NSFileProviderError where error.code == .cannotSynchronize {
            completionHandler(nil, changedFields, false, error)
        } catch {
            logger.error("Failed to update synced item metadata: \(DiagnosticFailure(error).summary, privacy: .public)")
            completionHandler(nil, [], false, error)
        }
        return Progress()
    }

    /// Applies rename, move, content, and tag changes to a user item and returns the saved row.
    ///
    /// Disk and path changes come first. If a later step fails, they are undone in reverse
    /// so the database never points at a path that is no longer there.
    private func updateUserItem(
        _ localItem: LocalItem,
        item: NSFileProviderItem,
        changedFields: NSFileProviderItemFields,
        newContents: URL?,
        db: Database
    ) throws -> LocalItem {
        var newFilename = localItem.filename
        var newParentID = localItem.parentID
        var newCourseID = localItem.courseID
        var newLocalPath = localItem.localPath
        var newFileSize = localItem.fileSize
        var newTagData = localItem.tagData

        var undoSteps: [() -> Void] = []
        func rollBack() {
            for step in undoSteps.reversed() {
                step()
            }
        }

        do {
            if changedFields.contains(.filename) {
                newFilename = item.filename
            }
            if changedFields.contains(.parentItemIdentifier) {
                let candidateParentID = item.parentItemIdentifier == .rootContainer
                    ? nil
                    : item.parentItemIdentifier.rawValue
                guard isReparentAllowed(itemID: localItem.id, newParentID: candidateParentID, db: db) else {
                    logger.error("Rejected reparent of \(localItem.id, privacy: .private) to \(candidateParentID ?? "root", privacy: .private) — missing parent or cycle")
                    throw NSFileProviderError(.cannotSynchronize)
                }
                newParentID = candidateParentID
                newCourseID = try newParentID.flatMap { try db.fetchItem(id: $0) }?.courseID ?? 0
            }

            if changedFields.contains(.filename) || changedFields.contains(.parentItemIdentifier) {
                guard let oldPath = localItem.localPath else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let oldURL = URL(fileURLWithPath: oldPath)
                // Avoid shadowing a Moodle item or stand-in in the destination folder.
                let clashes: Bool
                do {
                    clashes = try hasNonUserSiblingClash(
                        filename: newFilename,
                        parentID: newParentID,
                        siteID: localItem.siteID,
                        excludingID: localItem.id,
                        db: db
                    )
                } catch {
                    logger.error("modifyItem could not read siblings: \(DiagnosticFailure(error).summary, privacy: .public)")
                    throw NSFileProviderError(.serverUnreachable)
                }
                if clashes {
                    newFilename = PersonalFileStore.mineFilename(for: newFilename)
                }
                let directory = try personalFiles.directory(
                    forParentID: newParentID,
                    siteID: localItem.siteID,
                    siteName: siteName(for: localItem.siteID, database: db),
                    database: db
                )
                let desiredURL = directory.appendingPathComponent(newFilename, isDirectory: localItem.isDirectory)

                if desiredURL.standardizedFileURL.path != oldURL.standardizedFileURL.path {
                    let destination: URL
                    if oldURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                       oldURL.lastPathComponent.caseInsensitiveCompare(newFilename) == .orderedSame {
                        // Case-only rename. The name is taken by the item itself, so no numbering.
                        destination = desiredURL
                        try Self.renameEntry(at: oldURL, to: destination)
                        undoSteps.append { try? Self.renameEntry(at: destination, to: oldURL) }
                    } else {
                        destination = personalFiles.uniqueURL(for: newFilename, in: directory)
                        try FileManager.default.moveItem(at: oldURL, to: destination)
                        undoSteps.append { try? FileManager.default.moveItem(at: destination, to: oldURL) }
                    }
                    newLocalPath = destination.path
                    newFilename = destination.lastPathComponent

                    if localItem.isDirectory {
                        // Rows inside the folder keep their own paths, so rewrite their prefix.
                        try db.updateLocalPaths(fromPrefix: oldURL.path, toPrefix: destination.path, siteID: localItem.siteID)
                        undoSteps.append {
                            _ = try? db.updateLocalPaths(fromPrefix: destination.path, toPrefix: oldURL.path, siteID: localItem.siteID)
                        }
                    }
                }
            }

            if changedFields.contains(.contents), let newContents {
                guard let path = newLocalPath else {
                    throw NSFileProviderError(.noSuchItem)
                }
                let target = URL(fileURLWithPath: path)
                // Stage beside the file, then swap it in, so a failed copy leaves the old content intact.
                let staging = personalFiles.stagingURL(in: target.deletingLastPathComponent())
                try FileManager.default.copyItem(at: newContents, to: staging)
                do {
                    try PersonalFileStore.setItemID(localItem.id, at: staging)
                    if FileManager.default.fileExists(atPath: target.path) {
                        _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
                    } else {
                        try FileManager.default.moveItem(at: staging, to: target)
                    }
                    // replaceItemAt may not carry the attribute over, so set it on the final file.
                    try PersonalFileStore.setItemID(localItem.id, at: target)
                } catch {
                    try? FileManager.default.removeItem(at: staging)
                    throw error
                }
                newFileSize = Self.fileSize(at: target)
            }

            if changedFields.contains(.tagData) {
                newTagData = item.tagData ?? nil
            }
        } catch {
            rollBack()
            throw error
        }

        let updated = LocalItem(
            id: localItem.id,
            parentID: newParentID,
            siteID: localItem.siteID,
            courseID: newCourseID,
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

        do {
            try db.saveItems([updated])
        } catch {
            logger.error("modifyItem failed to save row: \(DiagnosticFailure(error).summary, privacy: .public)")
            rollBack()
            throw NSFileProviderError(.serverUnreachable)
        }
        return updated
    }

    /// Whether moving `itemID` under `newParentID` is structurally valid.
    /// Rejects moves whose new parent is missing or not a directory, or that would
    /// place the item inside itself or one of its descendants (a cycle). Moving to
    /// the root (`nil`) is always allowed. The new parent may be any kind of
    /// directory: a user folder, a Moodle folder, or a stand-in.
    private func isReparentAllowed(itemID: String, newParentID: String?, db: Database) -> Bool {
        guard let newParentID else { return true }
        if newParentID == itemID { return false }

        guard let newParent = try? db.fetchItem(id: newParentID), isContainer(newParent) else {
            return false
        }

        // Walk the ancestor chain of the proposed parent. If it leads back to
        // the item being moved, the move would create a cycle. A missing
        // ancestor means the chain is orphaned, so reject that too. `visited`
        // guards against pre-existing corrupt loops in the data.
        var cursor: String? = newParentID
        var visited: Set<String> = []
        while let current = cursor {
            if current == itemID { return false }
            guard visited.insert(current).inserted else { return false }
            guard let parent = try? db.fetchItem(id: current) else { return false }
            cursor = parent.parentID
        }
        return true
    }

    // MARK: - Maintenance

    // Legacy LocalContent can contain the only surviving copy of personal
    // files after cache loss or a database reset. Missing cache rows and file
    // age are not evidence of user deletion, so enumeration never sweeps it.

    /// Removes the disk content of a deleted user item. Removing its own folder takes its
    /// children with it. Any other returned path is removed only if it lies inside the
    /// personal files folder, so a stray row can never delete something outside it.
    private func removeDeletedContent(ownPath: String?, deletedPaths: [String]) {
        let folderPrefix = ownPath.map { $0 + "/" }
        let storeRoot = personalFiles.rootURL.standardizedFileURL.path + "/"

        var targets: [String] = []
        if let ownPath {
            targets.append(ownPath)
        }
        for path in deletedPaths where path != ownPath {
            if let folderPrefix, path.hasPrefix(folderPrefix) {
                continue // Goes with the folder.
            }
            if path.hasPrefix(storeRoot) {
                targets.append(path)
            }
        }

        for path in targets where FileManager.default.fileExists(atPath: path) {
            // The store holds the only copy of the user's file, so prefer the Trash
            // over an immediate delete. That leaves a way back from a mistaken delete.
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                continue
            } catch {
                logger.info("Could not move \(path, privacy: .public) to the Trash, deleting it: \(DiagnosticFailure(error).summary, privacy: .public)")
            }
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                logger.warning("Failed to remove content for deleted item at \(path, privacy: .public): \(DiagnosticFailure(error).summary, privacy: .public)")
            }
        }
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        guard let db = database else {
            completionHandler(NSFileProviderError(.serverUnreachable))
            return Progress()
        }

        let localItem: LocalItem
        switch lookupItem(id: identifier.rawValue, database: db) {
        case .found(let item):
            localItem = item
        case .missing:
            completionHandler(NSFileProviderError(.noSuchItem))
            return Progress()
        case .failed:
            completionHandler(NSFileProviderError(.serverUnreachable))
            return Progress()
        }

        // Only user items can be deleted. Synced items and stand-ins can't be deleted
        // through Finder — surface the proper File Provider error so the OS
        // restores the file rather than leaving the Finder UI inconsistent.
        guard isUserItem(localItem) else {
            completionHandler(NSFileProviderError(.cannotSynchronize))
            return Progress()
        }

        do {
            // Delete the rows first. If that fails, the content must survive so the
            // item is still usable. Content is removed only after the rows are gone.
            let deletedPaths = try db.deleteItemAndChildren(id: localItem.id)
            removeDeletedContent(ownPath: localItem.localPath, deletedPaths: deletedPaths)
            completionHandler(nil)
        } catch {
            logger.error("deleteItem failed: \(DiagnosticFailure(error).summary, privacy: .public)")
            completionHandler(error)
        }

        return Progress()
    }
}
