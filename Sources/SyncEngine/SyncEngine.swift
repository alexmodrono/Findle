// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import OSLog
import SharedDomain
import FoodleNetworking
import FoodlePersistence

/// Orchestrates synchronization between Moodle servers and local state.
public actor SyncEngine {
    private let provider: LMSProvider
    private let database: Database
    private let logger = Logger(subsystem: "es.amodrono.foodle.sync", category: "SyncEngine")

    private var activeTasks: [Int: Task<Void, Error>] = [:]
    private var syncProgress: [Int: SyncProgress] = [:]

    public struct SyncProgress: Sendable {
        public let courseID: Int
        public var totalItems: Int
        public var processedItems: Int
        public var state: CourseSubscriptionState

        public var fractionCompleted: Double {
            guard totalItems > 0 else { return 0 }
            return Double(processedItems) / Double(totalItems)
        }
    }

    public init(provider: LMSProvider, database: Database) {
        self.provider = provider
        self.database = database
    }

    // MARK: - Course Sync

    /// Sync all subscribed courses for a site.
    public func syncAllCourses(site: MoodleSite, token: AuthToken, courses: [MoodleCourse]) async {
        logger.info("Starting sync for \(courses.count) courses on \(site.displayName, privacy: .public)")

        for course in courses {
            guard activeTasks[course.id] == nil else {
                logger.debug("Skipping course \(course.id) - sync already in progress")
                continue
            }

            let task = Task {
                try await syncCourse(site: site, token: token, course: course)
            }
            activeTasks[course.id] = task

            do {
                try await task.value
                logger.info("Sync completed for course \(course.id, privacy: .public)")
            } catch {
                logger.error("Sync failed for course \(course.id): \(error.localizedDescription, privacy: .public)")
            }

            activeTasks[course.id] = nil
        }
    }

    /// Sync a single course: enumerate content, diff against local state, update database.
    public func syncCourse(site: MoodleSite, token: AuthToken, course: MoodleCourse) async throws {
        logger.info("Syncing course: \(course.fullName, privacy: .public)")

        syncProgress[course.id] = SyncProgress(
            courseID: course.id,
            totalItems: 0,
            processedItems: 0,
            state: .syncing
        )

        // Fetch remote content tree
        let sections = try await provider.fetchCourseContents(site: site, token: token, courseID: course.id)

        // Look up Finder tags for this course
        let courseTags = try database.fetchCourseTags(courseID: course.id, siteID: site.id)
        let courseTagData = FinderTag.tagData(from: courseTags)

        // Create the course root folder item
        let courseItemID = "course-\(site.id)-\(course.id)"
        let courseItem = LocalItem(
            id: courseItemID,
            parentID: nil,
            siteID: site.id,
            courseID: course.id,
            remoteID: course.id,
            filename: course.effectiveFolderName,
            isDirectory: true,
            creationDate: course.startDate,
            modificationDate: Date(),
            syncState: .materialized,
            tagData: courseTagData
        )

        var allItems: [LocalItem] = [courseItem]

        // Build items from sections and modules
        for section in sections {
            guard section.visible else { continue }

            let sectionItemID = "section-\(site.id)-\(course.id)-\(section.id)"
            let sectionItem = LocalItem(
                id: sectionItemID,
                parentID: courseItemID,
                siteID: site.id,
                courseID: course.id,
                remoteID: section.id,
                filename: section.sanitizedFolderName,
                isDirectory: true,
                modificationDate: Date(),
                syncState: .materialized
            )
            allItems.append(sectionItem)

            for module in section.modules {
                guard module.visible else { continue }
                let moduleItems = buildItems(
                    from: module,
                    parentID: sectionItemID,
                    siteID: site.id,
                    courseID: course.id,
                    token: token
                )
                allItems.append(contentsOf: moduleItems)
            }
        }

        syncProgress[course.id]?.totalItems = allItems.count

        // Diff against existing items
        let existingItems = try database.fetchAllItems(siteID: site.id).filter { $0.courseID == course.id }

        let changes = diffItems(existing: existingItems, incoming: allItems)

        // Apply changes
        if !changes.added.isEmpty || !changes.modified.isEmpty {
            try database.saveItems(changes.added + changes.modified)
        }
        for removed in changes.removed {
            try database.updateItemSyncState(id: removed.id, state: .placeholder)
        }

        // Update sync cursor
        let cursor = SyncCursor(
            courseID: course.id,
            siteID: site.id,
            lastSyncDate: Date(),
            lastModified: Date(),
            itemCount: allItems.count
        )
        try database.saveSyncCursor(cursor)

        syncProgress[course.id]?.processedItems = allItems.count
        syncProgress[course.id]?.state = .synced

        // Auto-download pinned items that aren't yet materialized
        await downloadPinnedItems(site: site, token: token)

        logger.info("Course \(course.id) sync complete: \(allItems.count) items")
    }

    /// Download all pinned items that are not yet materialized.
    private func downloadPinnedItems(site: MoodleSite, token: AuthToken) async {
        do {
            let pinnedItems = try database.fetchPinnedItems(siteID: site.id)
            let pending = pinnedItems.filter { $0.syncState != .materialized }

            guard !pending.isEmpty else { return }
            logger.info("Downloading \(pending.count) pinned items")

            for item in pending {
                guard item.remoteURL != nil else { continue }
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(item.filename)
                do {
                    try await downloadItem(
                        itemID: item.id,
                        site: site,
                        token: token,
                        destination: destination
                    )
                } catch {
                    logger.error("Failed to download pinned item \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            logger.error("Failed to fetch pinned items: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Item Building

    private func buildItems(
        from module: MoodleModule,
        parentID: String,
        siteID: String,
        courseID: Int,
        token: AuthToken
    ) -> [LocalItem] {
        var items: [LocalItem] = []

        switch module.resourceType {
        case .file:
            for content in module.contents where content.type == "file" {
                let itemID = "file-\(siteID)-\(courseID)-\(module.id)-\(content.fileName)"
                let item = LocalItem(
                    id: itemID,
                    parentID: parentID,
                    siteID: siteID,
                    courseID: courseID,
                    remoteID: module.id,
                    filename: FileNameSanitizer.sanitize(content.fileName, preserveExtension: true),
                    isDirectory: false,
                    contentType: content.mimeType,
                    fileSize: content.fileSize,
                    creationDate: content.timeCreated,
                    modificationDate: content.timeModified,
                    syncState: .placeholder,
                    remoteURL: content.fileURL,
                    contentVersion: content.timeModified.map { String(Int($0.timeIntervalSince1970)) }
                )
                items.append(item)
            }

        case .folder:
            let folderID = "folder-\(siteID)-\(courseID)-\(module.id)"
            let folder = LocalItem(
                id: folderID,
                parentID: parentID,
                siteID: siteID,
                courseID: courseID,
                remoteID: module.id,
                filename: FileNameSanitizer.sanitize(module.name),
                isDirectory: true,
                modificationDate: Date(),
                syncState: .materialized
            )
            items.append(folder)

            for content in module.contents where content.type == "file" {
                let itemID = "file-\(siteID)-\(courseID)-\(module.id)-\(content.fileName)"
                let item = LocalItem(
                    id: itemID,
                    parentID: folderID,
                    siteID: siteID,
                    courseID: courseID,
                    remoteID: module.id,
                    filename: FileNameSanitizer.sanitize(content.fileName, preserveExtension: true),
                    isDirectory: false,
                    contentType: content.mimeType,
                    fileSize: content.fileSize,
                    creationDate: content.timeCreated,
                    modificationDate: content.timeModified,
                    syncState: .placeholder,
                    remoteURL: content.fileURL,
                    contentVersion: content.timeModified.map { String(Int($0.timeIntervalSince1970)) }
                )
                items.append(item)
            }

        case .url:
            // Represent URL resources as .webloc files
            if let content = module.contents.first, let urlString = content.fileURL?.absoluteString {
                let itemID = "url-\(siteID)-\(courseID)-\(module.id)"
                let item = LocalItem(
                    id: itemID,
                    parentID: parentID,
                    siteID: siteID,
                    courseID: courseID,
                    remoteID: module.id,
                    filename: FileNameSanitizer.sanitize(module.name) + ".webloc",
                    isDirectory: false,
                    contentType: "com.apple.web-internet-location",
                    fileSize: Int64(urlString.utf8.count + 200),
                    modificationDate: content.timeModified,
                    syncState: .placeholder,
                    remoteURL: content.fileURL
                )
                items.append(item)
            }

        case .page:
            // Represent page resources as HTML files
            let itemID = "page-\(siteID)-\(courseID)-\(module.id)"
            let item = LocalItem(
                id: itemID,
                parentID: parentID,
                siteID: siteID,
                courseID: courseID,
                remoteID: module.id,
                filename: FileNameSanitizer.sanitize(module.name) + ".html",
                isDirectory: false,
                contentType: "text/html",
                fileSize: 0,
                modificationDate: Date(),
                syncState: .placeholder
            )
            items.append(item)

        default:
            break
        }

        return items
    }

    // MARK: - Diffing

    private struct DiffResult {
        let added: [LocalItem]
        let modified: [LocalItem]
        let removed: [LocalItem]
    }

    private func diffItems(existing: [LocalItem], incoming: [LocalItem]) -> DiffResult {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })

        var added: [LocalItem] = []
        var modified: [LocalItem] = []
        var removed: [LocalItem] = []

        for (id, var item) in incomingByID {
            if let existing = existingByID[id] {
                // Preserve user-set pin state across syncs
                item.isPinned = existing.isPinned

                if existing.contentVersion != item.contentVersion ||
                   existing.fileSize != item.fileSize ||
                   existing.filename != item.filename {
                    modified.append(item)
                }
            } else {
                added.append(item)
            }
        }

        for (id, item) in existingByID {
            if incomingByID[id] == nil {
                removed.append(item)
            }
        }

        return DiffResult(added: added, modified: modified, removed: removed)
    }

    // MARK: - Download

    /// Download a specific item's content.
    public func downloadItem(
        itemID: String,
        site: MoodleSite,
        token: AuthToken,
        destination: URL
    ) async throws {
        guard let item = try database.fetchItem(id: itemID) else {
            throw FoodleError.itemNotFound(itemID: itemID)
        }

        guard let remoteURL = item.remoteURL else {
            throw FoodleError.downloadFailed(itemID: itemID, reason: "No remote URL")
        }

        try database.updateItemSyncState(id: itemID, state: .downloading)

        do {
            try await provider.downloadFile(url: remoteURL, token: token, destination: destination)
            try database.updateItemSyncState(id: itemID, state: .materialized, localPath: destination.path)
            logger.info("Downloaded item \(itemID, privacy: .public)")
        } catch {
            try database.updateItemSyncState(id: itemID, state: .error)
            throw error
        }
    }

    // MARK: - Cancellation

    public func cancelSync(courseID: Int) {
        activeTasks[courseID]?.cancel()
        activeTasks[courseID] = nil
        syncProgress[courseID]?.state = .stale
    }

    public func cancelAllSyncs() {
        for (id, task) in activeTasks {
            task.cancel()
            syncProgress[id]?.state = .stale
        }
        activeTasks.removeAll()
    }

    // MARK: - Progress

    public func progress(forCourse courseID: Int) -> SyncProgress? {
        syncProgress[courseID]
    }

    public func allProgress() -> [Int: SyncProgress] {
        syncProgress
    }
}
