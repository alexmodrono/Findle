// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import OSLog
import SharedDomain
import UniformTypeIdentifiers

/// Brings the database in line with the personal files folder on disk.
///
/// The folder is the source of truth. The `local-` rows in the database are a cache
/// that can be rebuilt from it, and stand-in rows recreate Moodle directories so user
/// files stay visible when their course is not synced.
public struct PersonalFilesReconciler {
    private static let logger = Logger(subsystem: "es.amodrono.findle.persistence", category: "PersonalFiles")
    private static let localPrefix = "local-"

    private let store: PersonalFileStore
    private let database: Database

    public init(store: PersonalFileStore, database: Database) {
        self.store = store
        self.database = database
    }

    /// Reconciles one Moodle site. Returns `true` when any database row was saved,
    /// deleted, or pruned, so the caller knows to signal Finder.
    ///
    /// Steps, in order:
    /// 1. Copy legacy `local-` content (rows whose files live outside the store) into the store.
    /// 2. Import everything found on disk, creating stand-in and user rows as needed.
    /// 3. Delete unchanged `local-` rows that are no longer on disk, but only if the site folder
    ///    existed before this run and the complete scan is still current.
    /// 4. Rename user items that now share a name with a Moodle item or stand-in in their folder.
    /// 5. Prune stand-ins for courses that are unsynced or unknown, then remove empty anchor folders.
    @discardableResult
    public func reconcile(siteID: String, siteName: String) throws -> Bool {
        // Decided before anything can create the site folder. If the store was missing,
        // deletion must not treat every row as absent.
        let existingDirectory = try store.existingSiteDirectory(siteID: siteID)
        let initialRows = try database.fetchLocalItems(siteID: siteID)

        let migration = try migrateLegacyContent(siteID: siteID, siteName: siteName)
        let imported = try importFromDisk(siteID: siteID, protectedIDs: migration.conflictedIDs)
        var changed = migration.changed || imported.changed
        var canCleanEmptyAnchors = true

        if let existingDirectory {
            guard imported.snapshot.siteDirectory == existingDirectory else {
                throw PersonalFileStoreError.incompleteScan(path: store.rootURL.path)
            }
            try store.validate(imported.snapshot, siteID: siteID)
            var stale: [LocalItem] = []
            for row in initialRows where row.id.hasPrefix(Self.localPrefix)
                && !imported.seenIDs.contains(row.id) && !migration.unmigratedIDs.contains(row.id) {
                // Hidden files and symlinks still exist and stay tracked. The
                // database compares row versions and children under its write lock.
                guard let path = row.localPath,
                      try store.isDefinitelyAbsent(URL(fileURLWithPath: path)) else { continue }
                stale.append(row)
            }
            try store.validate(imported.snapshot, siteID: siteID)
            let deleted = try database.deleteLocalItemsIfUnchanged(stale)
            if deleted > 0 { changed = true }
            // A conflicting row may represent Finder content still arriving.
            // Keep its on-disk anchor markers until a later complete pass.
            canCleanEmptyAnchors = deleted == stale.count
        } else {
            Self.logger.info("Personal files folder for site \(siteID, privacy: .private) was absent; skipping deletions")
        }

        if try resolveNameClashes(siteID: siteID) {
            changed = true
        }

        let courses = try database.fetchCourses(siteID: siteID)
        let knownCourseIDs = Set(courses.map(\.id))
        let unsyncedCourseIDs = courses.filter { !$0.isSyncEnabled }.map(\.id)
        let orphanedCourseIDs = try database.fetchLocalItems(siteID: siteID)
            .filter { !$0.id.hasPrefix(Self.localPrefix) && !knownCourseIDs.contains($0.courseID) }
            .map(\.courseID)
        let prunable = Array(Set(unsyncedCourseIDs + orphanedCourseIDs)).sorted()
        if !prunable.isEmpty {
            let pruned = try database.pruneDirectoriesWithoutLocalContent(courseIDs: prunable, siteID: siteID)
            if pruned > 0 {
                changed = true
            }
        }
        if canCleanEmptyAnchors { try store.removeEmptyAnchorDirectories(siteID: siteID) }

        return changed
    }

    // MARK: - Step 1: legacy migration

    private struct MigrationResult {
        var changed: Bool
        /// Legacy rows that could not be moved. They stay in the database and are never deleted.
        var unmigratedIDs: Set<String>
        /// Finder changed these rows while a legacy copy was in progress.
        /// The importer must not immediately undo the guarded migration skip.
        var conflictedIDs: Set<String>
    }

    private func migrateLegacyContent(siteID: String, siteName: String) throws -> MigrationResult {
        let legacy = try database.fetchLocalItems(siteID: siteID).filter { needsMigration($0) }
        guard !legacy.isEmpty else {
            return MigrationResult(changed: false, unmigratedIDs: [], conflictedIDs: [])
        }

        // Parents first, so a child's target directory already has its new localPath.
        var ordered: [(row: LocalItem, depth: Int)] = []
        for row in legacy {
            ordered.append((row, try depth(of: row)))
        }
        ordered.sort { ($0.depth, $0.row.id) < ($1.depth, $1.row.id) }

        var changed = false
        var unmigrated = Set<String>()
        var conflicted = Set<String>()
        // A previous run may have published a file then stopped before its
        // database write. Reuse that stable identity instead of copying again.
        let recoveredEntries = try store.scan(siteID: siteID)
        let recoveredByID = Dictionary(grouping: recoveredEntries.filter { $0.storedItemID != nil }, by: { $0.storedItemID! })

        for (row, _) in ordered {
            if let parentID = row.parentID, unmigrated.contains(parentID) {
                Self.logger.error("Leaving \(row.id, privacy: .private) in place because its parent was not migrated")
                unmigrated.insert(row.id)
                if conflicted.contains(parentID) { conflicted.insert(row.id) }
                continue
            }
            do {
                var recovered = recoveredByID[row.id]
                if !row.isDirectory, let oldPath = row.localPath, Self.fileExists(atPath: oldPath),
                   let candidate = recovered?.first,
                   !FileManager.default.contentsEqual(atPath: oldPath, andPath: candidate.url.path) {
                    // The legacy original was edited after an interrupted copy.
                    // Publish a new copy; retain the earlier one under its own ID.
                    recovered = nil
                }
                if let recovered {
                    guard recovered.count == 1, let entry = recovered.first else {
                        throw PersonalFileStoreError.incompleteScan(path: store.rootURL.path)
                    }
                    if try database.saveLocalItemsIfUnchanged([
                        .init(item: Self.relocated(row, to: entry.url), expected: row)
                    ]) > 0 {
                        changed = true
                    } else {
                        unmigrated.insert(row.id)
                        conflicted.insert(row.id)
                    }
                    continue
                }
                let target = try store.directory(forParentID: row.parentID, siteID: siteID, siteName: siteName, database: database)
                if row.isDirectory {
                    let newURL = try store.createUserDirectory(named: row.filename, in: target)
                    do {
                        try store.writeItemID(row.id, at: newURL)
                    } catch {
                        // Another process may already have added a child. Only
                        // remove an empty failed destination, never its contents.
                        _ = newURL.path.withCString { rmdir($0) }
                        throw error
                    }
                    if try database.saveLocalItemsIfUnchanged([
                        .init(item: Self.relocated(row, to: newURL), expected: row)
                    ]) > 0 {
                        changed = true
                    } else {
                        unmigrated.insert(row.id)
                        conflicted.insert(row.id)
                    }
                } else {
                    guard let oldPath = row.localPath, Self.fileExists(atPath: oldPath) else {
                        Self.logger.error("Legacy file for \(row.id, privacy: .private) is missing; leaving its row in place")
                        unmigrated.insert(row.id)
                        continue
                    }
                    let staging = store.stagingURL(in: target)
                    // Even a partially copied staging file is disposable; the
                    // legacy original is retained through failures and replay.
                    defer { try? FileManager.default.removeItem(at: staging) }
                    try store.copyItem(at: URL(fileURLWithPath: oldPath), to: staging)
                    try store.writeItemID(row.id, at: staging)
                    let newURL = store.uniqueURL(for: row.filename, in: target)
                    try store.moveItem(at: staging, to: newURL)
                    if try database.saveLocalItemsIfUnchanged([
                        .init(item: Self.relocated(row, to: newURL), expected: row)
                    ]) > 0 {
                        changed = true
                    } else {
                        unmigrated.insert(row.id)
                        conflicted.insert(row.id)
                    }
                    // Keep the legacy original as a recovery copy. An editor
                    // may still hold it open or save after this copy completed;
                    // deleting it here could remove the only version of that edit.
                }
            } catch {
                Self.logger.error("Could not migrate \(row.id, privacy: .private): \(DiagnosticFailure(error).summary, privacy: .public)")
                unmigrated.insert(row.id)
            }
        }

        return MigrationResult(changed: changed, unmigratedIDs: unmigrated, conflictedIDs: conflicted)
    }

    /// Copy of `row` pointing at `url`, with the filename taken from the new location.
    private static func relocated(_ row: LocalItem, to url: URL) -> LocalItem {
        LocalItem(
            id: row.id,
            parentID: row.parentID,
            siteID: row.siteID,
            courseID: row.courseID,
            remoteID: row.remoteID,
            filename: url.lastPathComponent,
            isDirectory: row.isDirectory,
            contentType: row.contentType,
            fileSize: row.fileSize,
            creationDate: row.creationDate,
            modificationDate: row.modificationDate,
            syncState: row.syncState,
            isPinned: row.isPinned,
            localPath: url.path,
            remoteURL: row.remoteURL,
            contentVersion: row.contentVersion,
            tagData: row.tagData,
            isLocal: row.isLocal
        )
    }

    /// A `local-` directory with no path, or any `local-` row whose path is outside the store.
    /// Files without a path have no content to move and are left to step 3.
    private func needsMigration(_ row: LocalItem) -> Bool {
        guard row.id.hasPrefix(Self.localPrefix) else { return false }
        guard let path = row.localPath else { return row.isDirectory }
        return !isInsideStore(path)
    }

    private func isInsideStore(_ path: String) -> Bool {
        Self.canonicalPath(URL(fileURLWithPath: path)).hasPrefix(Self.canonicalPath(store.rootURL) + "/")
    }

    private func depth(of row: LocalItem) throws -> Int {
        var depth = 0
        var parentID = row.parentID
        while let id = parentID, depth < 1_000 {
            depth += 1
            parentID = try database.fetchItem(id: id)?.parentID
        }
        return depth
    }

    // MARK: - Step 2: import from disk

    private struct ImportResult {
        var changed: Bool
        /// Every user item id found on disk during this run.
        var seenIDs: Set<String>
        var snapshot: PersonalFileStore.ScanSnapshot
    }

    private func importFromDisk(siteID: String, protectedIDs: Set<String>) throws -> ImportResult {
        let snapshot = try store.snapshot(siteID: siteID)
        let entries = snapshot.entries
        let existingRows = try database.fetchLocalItems(siteID: siteID)
        let existingByPath = Dictionary(existingRows.compactMap { row -> (String, LocalItem)? in
            row.localPath.map { (Self.canonicalPath(URL(fileURLWithPath: $0)), row) }
        }, uniquingKeysWith: { first, _ in first })
        let scannedPaths = Set(entries.map { Self.canonicalPath($0.url) })
        let now = Date()

        var itemIDByDirectory: [String: String] = [:]
        var courseIDByDirectory: [String: Int] = [:]
        var usedIDs = Set<String>()
        var seenIDs = Set<String>()
        var rowsToSave: [Database.LocalItemUpdate] = []

        for entry in entries {
            let path = Self.canonicalPath(entry.url)
            let parentPath = Self.canonicalPath(entry.parentURL)
            let parentItemID = itemIDByDirectory[parentPath]
            let inheritedCourseID = courseIDByDirectory[parentPath] ?? 0

            switch entry.kind {
            case .anchor(let anchor):
                itemIDByDirectory[path] = anchor.itemID
                courseIDByDirectory[path] = anchor.courseID
                if try database.fetchItem(id: anchor.itemID) == nil {
                    rowsToSave.append(Database.LocalItemUpdate(item: LocalItem(
                        id: anchor.itemID,
                        parentID: anchor.parentItemID,
                        siteID: siteID,
                        courseID: anchor.courseID,
                        remoteID: 0,
                        filename: anchor.name,
                        isDirectory: true,
                        modificationDate: now,
                        syncState: .materialized,
                        localPath: entry.url.path,
                        isLocal: true
                    ), expected: nil))
                }

            case .userFolder, .userFile:
                let isDirectory: Bool
                if case .userFolder = entry.kind { isDirectory = true } else { isDirectory = false }

                if let existing = existingByPath[path], !existing.id.hasPrefix(Self.localPrefix) {
                    throw PersonalFileStoreError.invalidMarker(path: entry.url.path)
                }
                let id = try resolveID(for: entry, siteID: siteID, existingByPath: existingByPath, scannedPaths: scannedPaths, usedIDs: &usedIDs)
                seenIDs.insert(id)
                if isDirectory {
                    itemIDByDirectory[path] = id
                    courseIDByDirectory[path] = inheritedCourseID
                }

                guard !protectedIDs.contains(id) else { continue }
                let values = try entry.url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
                let existing = try database.fetchItem(id: id)
                let item = LocalItem(
                    id: id,
                    parentID: parentItemID,
                    siteID: siteID,
                    courseID: inheritedCourseID,
                    remoteID: 0,
                    filename: entry.url.lastPathComponent,
                    isDirectory: isDirectory,
                    contentType: isDirectory ? nil : UTType(filenameExtension: entry.url.pathExtension)?.preferredMIMEType,
                    fileSize: isDirectory ? 0 : Int64(values.fileSize ?? 0),
                    creationDate: existing?.creationDate ?? values.creationDate,
                    modificationDate: values.contentModificationDate,
                    syncState: .materialized,
                    isPinned: existing?.isPinned ?? false,
                    localPath: entry.url.path,
                    tagData: existing?.tagData,
                    isLocal: true
                )
                if let existing, !Self.needsSave(existing: existing, updated: item) {
                    continue
                }
                rowsToSave.append(Database.LocalItemUpdate(item: item, expected: existing))
            }
        }

        try store.validate(snapshot, siteID: siteID)
        let saved = try database.saveLocalItemsIfUnchanged(rowsToSave)
        return ImportResult(changed: saved > 0, seenIDs: seenIDs, snapshot: snapshot)
    }

    /// Keeps the stored id when it is a `local-` id not already claimed in this scan.
    /// Otherwise (a duplicated file, or one without an id) assigns a fresh id and writes it to disk.
    private func resolveID(
        for entry: PersonalFileStore.ScannedEntry,
        siteID: String,
        existingByPath: [String: LocalItem],
        scannedPaths: Set<String>,
        usedIDs: inout Set<String>
    ) throws -> String {
        let path = Self.canonicalPath(entry.url)
        if let stored = entry.storedItemID, !usedIDs.contains(stored) {
            let owner = try database.fetchItem(id: stored)
            let ownerPath = owner?.localPath.map { Self.canonicalPath(URL(fileURLWithPath: $0)) }
            // A copied xattr must not steal the original's identity just because
            // the copy sorts before it. A moved original may keep its ID.
            if owner == nil || (owner?.siteID == siteID
                && (ownerPath == path || ownerPath.map { !scannedPaths.contains($0) } == true)) {
                usedIDs.insert(stored)
                return stored
            }
        }
        let id: String
        if entry.storedItemID == nil, let existing = existingByPath[path], !usedIDs.contains(existing.id) {
            id = existing.id
        } else {
            id = "\(Self.localPrefix)\(UUID().uuidString)"
        }
        // Never publish an ID that could not be persisted. A later scan would
        // otherwise replace it and tombstone the previous row.
        try store.writeItemID(id, at: entry.url)
        usedIDs.insert(id)
        return id
    }

    /// Whether `updated` differs from `existing` in a way worth writing back.
    private static func needsSave(existing: LocalItem, updated: LocalItem) -> Bool {
        existing.parentID != updated.parentID
            || existing.courseID != updated.courseID
            || existing.filename != updated.filename
            || existing.fileSize != updated.fileSize
            || !samePath(existing.localPath, updated.localPath)
            || existing.modificationDate?.timeIntervalSince1970 != updated.modificationDate?.timeIntervalSince1970
    }

    private static func samePath(_ lhs: String?, _ rhs: String?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (l?, r?):
            return canonicalPath(URL(fileURLWithPath: l)) == canonicalPath(URL(fileURLWithPath: r))
        default:
            return false
        }
    }

    // MARK: - Step 3: name clashes

    /// Renames each user item whose name matches a Moodle item or stand-in in the same folder,
    /// so Finder never shows two items with one name. Returns `true` when anything was renamed.
    private func resolveNameClashes(siteID: String) throws -> Bool {
        let localIDs = try database.fetchLocalItems(siteID: siteID)
            .map(\.id)
            .filter { $0.hasPrefix(Self.localPrefix) }
        var siblingsByParent: [String?: [LocalItem]] = [:]
        var changed = false

        for id in localIDs {
            // Re-read each row: renaming a folder rewrites the paths of the rows inside it.
            guard let row = try database.fetchItem(id: id), let path = row.localPath else { continue }

            let siblings: [LocalItem]
            if let cached = siblingsByParent[row.parentID] {
                siblings = cached
            } else {
                siblings = try database.fetchItems(parentID: row.parentID, siteID: siteID)
                siblingsByParent[row.parentID] = siblings
            }
            let clashes = siblings.contains {
                !$0.id.hasPrefix(Self.localPrefix) && $0.filename.lowercased() == row.filename.lowercased()
            }
            guard clashes else { continue }

            let source = URL(fileURLWithPath: path)
            let target = store.uniqueURL(
                for: PersonalFileStore.mineFilename(for: row.filename),
                in: source.deletingLastPathComponent()
            )
            do {
                try store.moveItem(at: source, to: target)
            } catch {
                Self.logger.error("Could not rename clashing item \(id, privacy: .private): \(DiagnosticFailure(error).summary, privacy: .public)")
                continue
            }

            var pathsMoved = false
            do {
                if row.isDirectory {
                    try database.updateLocalPaths(fromPrefix: path, toPrefix: target.path, siteID: siteID)
                    pathsMoved = true
                }
                try database.saveItems([Self.relocated(row, to: target)])
            } catch {
                Self.logger.error("Could not save renamed item \(id, privacy: .private): \(DiagnosticFailure(error).summary, privacy: .public)")
                if pathsMoved {
                    try? database.updateLocalPaths(fromPrefix: target.path, toPrefix: path, siteID: siteID)
                }
                try? store.moveItem(at: target, to: source)
                continue
            }
            changed = true
        }
        return changed
    }

    // MARK: - Path helpers

    /// Resolves symbolic links (for example `/var` to `/private/var`) so paths from different sources compare equal.
    /// Only the existing ancestor is resolved, so paths to files that were just removed still canonicalize.
    private static func canonicalPath(_ url: URL) -> String {
        let standardized = url.standardizedFileURL.path
        var existing = standardized
        var missing: [String] = []
        while existing != "/", (try? FileManager.default.attributesOfItem(atPath: existing)) == nil {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        var resolved = URL(fileURLWithPath: existing).resolvingSymlinksInPath().path
        for component in missing {
            resolved = (resolved as NSString).appendingPathComponent(component)
        }
        return resolved
    }

    private static func fileExists(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
