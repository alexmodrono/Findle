// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import OSLog
import SharedDomain
import FindleNetworking
import FindlePersistence

/// Orchestrates synchronization between Moodle servers and local state.
public actor SyncEngine {
    private let provider: LMSProvider
    private let database: Database
    private let logger = Logger(subsystem: "es.amodrono.findle.sync", category: "SyncEngine")

    private var activeTasks: [Int: Task<Date?, Error>] = [:]
    /// Pinned-item downloads in flight, tracked so `stopAllSyncs` can cancel and await them.
    private var pinnedDownloadTasks: Set<Task<[Int: DiagnosticFailure], Error>> = []
    private var syncProgress: [Int: SyncProgress] = [:]
    private var isStopping = false

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

    /// How many courses may be fetched from the server at once. Course syncs are
    /// independent, so running them serially made a full sync cost the sum of
    /// every round trip. The cap keeps us from opening an unbounded number of
    /// connections to a shared institutional Moodle.
    public static let defaultCourseConcurrency = 4

    /// Sync selected courses with bounded concurrency and account for every outcome.
    /// Authentication failures stop scheduling and cancel siblings. Other failures
    /// preserve committed courses and allow the remaining selections to proceed.
    @discardableResult
    public func syncAllCourses(
        site: MoodleSite,
        token: AuthToken,
        courses: [MoodleCourse],
        maxConcurrentCourses: Int = SyncEngine.defaultCourseConcurrency,
        onCourseSynced: (@Sendable (Int) -> Void)? = nil
    ) async -> SyncRunReport {
        let attemptID = UUID()
        let startedAt = Date()
        let journal = DiagnosticJournal(databasePath: database.filePath)
        // A duplicate selection must not produce duplicate callbacks or inflated counts.
        var seen = Set<Int>()
        let selected = courses.filter { seen.insert($0.id).inserted }
        guard !selected.isEmpty else {
            return SyncRunReport(id: attemptID, siteID: site.id, startedAt: startedAt, courses: [])
        }
        journal?.record(DiagnosticEvent(attemptID: attemptID, process: .app, operation: .sync, outcome: .started))
        for course in selected {
            syncProgress[course.id] = SyncProgress(courseID: course.id, totalItems: 0, processedItems: 0, state: .syncing)
        }

        var outcomes: [Int: SyncCourseOutcome] = [:]
        var wasCancelled = Task.isCancelled || isStopping
        var authenticationFailed = false
        var runFailure: DiagnosticFailure?
        let limit = max(1, min(maxConcurrentCourses, selected.count))

        await withTaskGroup(of: (SyncCourseOutcome, Bool).self) { group in
            var next = 0
            if !wasCancelled {
                while next < min(limit, selected.count) {
                    let course = selected[next]
                    group.addTask { [self] in
                        await syncCourseCapturingOutcome(site: site, token: token, course: course)
                    }
                    next += 1
                }
            }
            while let (result, needsAuthentication) = await group.next() {
                outcomes[result.courseID] = result
                if result.outcome == .succeeded {
                    onCourseSynced?(result.courseID)
                } else {
                    syncProgress[result.courseID]?.state = result.outcome == .failed ? .error : .stale
                }
                if needsAuthentication {
                    authenticationFailed = true
                    runFailure = result.failure
                    group.cancelAll()
                } else if result.outcome == .cancelled || Task.isCancelled {
                    wasCancelled = true
                    group.cancelAll()
                }
                guard !authenticationFailed, !wasCancelled, next < selected.count else { continue }
                let course = selected[next]
                group.addTask { [self] in
                    await syncCourseCapturingOutcome(site: site, token: token, course: course)
                }
                next += 1
            }
        }

        wasCancelled = wasCancelled || Task.isCancelled
        for course in selected where outcomes[course.id] == nil {
            // These courses were selected but never started after cancellation/auth failure.
            outcomes[course.id] = SyncCourseOutcome(
                courseID: course.id, outcome: .skipped,
                lastSuccessfulSync: (try? database.fetchSyncCursor(courseID: course.id, siteID: site.id))?.lastSyncDate
            )
            syncProgress[course.id]?.state = .stale
        }

        let published = Set(outcomes.values.filter { $0.outcome == .succeeded }.map(\.courseID))
        if !wasCancelled, !authenticationFailed, !published.isEmpty {
            do {
                let failures = try await runPinnedDownloads(site: site, token: token, courseIDs: published)
                for (courseID, failure) in failures {
                    guard let previous = outcomes[courseID] else { continue }
                    outcomes[courseID] = SyncCourseOutcome(
                        courseID: courseID, outcome: .incomplete, startedAt: previous.startedAt,
                        lastSuccessfulSync: previous.lastSuccessfulSync, failure: failure
                    )
                    syncProgress[courseID]?.state = .stale
                }
            } catch {
                runFailure = DiagnosticFailure(error)
                authenticationFailed = (error as? FindleError)?.requiresReauthentication == true
                wasCancelled = Self.isCancellation(error) || Task.isCancelled
            }
        }
        let report = SyncRunReport(
            id: attemptID, siteID: site.id, startedAt: startedAt,
            courses: selected.compactMap { outcomes[$0.id] }, wasCancelled: wasCancelled,
            requiresReauthentication: authenticationFailed, failure: runFailure
        )
        let journalOutcome: DiagnosticEvent.Outcome = report.allSucceeded ? .succeeded
            : report.requiresReauthentication ? .failed
            : report.wasCancelled ? .cancelled
            : report.succeededCount > 0 || report.incompleteCount > 0 ? .partial : .failed
        journal?.record(DiagnosticEvent(
            attemptID: report.id, process: .app, operation: .sync, outcome: journalOutcome,
            failure: report.failure ?? report.courses.compactMap(\.failure).first
        ))
        return report
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? FindleError)?.isCancelled == true
            || (error as? URLError)?.code == .cancelled
    }

    private func syncCourseCapturingOutcome(
        site: MoodleSite, token: AuthToken, course: MoodleCourse
    ) async -> (SyncCourseOutcome, Bool) {
        let startedAt = Date()
        var lastSuccess: Date?
        do {
            lastSuccess = try database.fetchSyncCursor(courseID: course.id, siteID: site.id)?.lastSyncDate
            try Task.checkCancellation()
            guard course.isSyncEnabled else {
                return (SyncCourseOutcome(courseID: course.id, outcome: .skipped, startedAt: startedAt,
                                          lastSuccessfulSync: lastSuccess), false)
            }
            let committedAt = try await syncCourseTracked(site: site, token: token, course: course)
            return (SyncCourseOutcome(courseID: course.id, outcome: committedAt == nil ? .skipped : .succeeded,
                                      startedAt: startedAt, lastSuccessfulSync: committedAt ?? lastSuccess), false)
        } catch {
            let outcome: SyncCourseOutcome.Outcome
            if Self.isCancellation(error) { outcome = .cancelled }
            else if case .invalidResponse = error as? FindleError { outcome = .incomplete }
            else { outcome = .failed }
            return (SyncCourseOutcome(courseID: course.id, outcome: outcome, startedAt: startedAt,
                                      lastSuccessfulSync: lastSuccess, failure: DiagnosticFailure(error)),
                    (error as? FindleError)?.requiresReauthentication == true)
        }
    }

    /// Sync a single course, then materialize any pinned items that still need
    /// downloading. Batch runs use `syncCourseTracked` directly and download
    /// pinned items once at the end instead.
    public func syncCourse(site: MoodleSite, token: AuthToken, course: MoodleCourse) async throws {
        guard try await syncCourseTracked(site: site, token: token, course: course) != nil else { return }
        let failures = try await runPinnedDownloads(site: site, token: token, courseIDs: [course.id])
        if !failures.isEmpty {
            throw FindleError.downloadFailed(itemID: "course-\(course.id)", reason: "Pinned files could not finish downloading. Try again.")
        }
    }

    /// Sync a single course: enumerate content, diff against local state, update database.
    private func syncCourseTracked(site: MoodleSite, token: AuthToken, course: MoodleCourse) async throws -> Date? {
        if isStopping {
            throw CancellationError()
        }

        if let activeTask = activeTasks[course.id] {
            do {
                return try await activeTask.value
            } catch is CancellationError {
                // The task we joined was cancelled by someone else. That must not
                // take down this run unless this caller was cancelled too.
                if Task.isCancelled { throw CancellationError() }
                throw FindleError.syncFailed(courseID: course.id, reason: "Joined sync was cancelled")
            }
        }

        let task = Task { [self] in
            try await performSyncCourse(site: site, token: token, course: course)
        }
        activeTasks[course.id] = task

        defer { clearActiveTask(task, courseID: course.id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Remove a course's entry only if it still refers to `task`. A newer task
    /// may have been registered for the same course while this one was running.
    private func clearActiveTask(_ task: Task<Date?, Error>, courseID: Int) {
        if activeTasks[courseID] == task {
            activeTasks[courseID] = nil
        }
    }

    /// Whether the user still has this course subscribed. Writes from a sync
    /// that started before an unsubscribe would otherwise resurrect its items.
    /// A course row that no longer exists is treated as still subscribed.
    private func isCourseSubscribed(courseID: Int, siteID: String) throws -> Bool {
        guard let course = try database.fetchCourses(siteID: siteID).first(where: { $0.id == courseID }) else {
            return true
        }
        return course.isSyncEnabled
    }

    private func performSyncCourse(site: MoodleSite, token: AuthToken, course: MoodleCourse) async throws -> Date? {
        logger.info("Syncing course: \(course.fullName, privacy: .public)")

        syncProgress[course.id] = SyncProgress(
            courseID: course.id,
            totalItems: 0,
            processedItems: 0,
            state: .syncing
        )

        try Task.checkCancellation()

        // Fetch remote content tree
        let sections = try await provider.fetchCourseContents(site: site, token: token, courseID: course.id)

        try Task.checkCancellation()

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

        try Task.checkCancellation()

        // Diff against existing items. Scope the query to this course so the
        // `idx_items_course` index does the filtering — loading every row for
        // the site and filtering in memory made a full sync quadratic.
        let existingItems = try database.fetchItems(courseID: course.id, siteID: site.id).filter { !$0.isLocal }

        let changes = diffItems(existing: existingItems, incoming: allItems)

        try Task.checkCancellation()

        // The network round trips above can be long. If the user unsubscribed in
        // the meantime, drop these results rather than writing the course back.
        guard try isCourseSubscribed(courseID: course.id, siteID: site.id) else {
            logger.info("Course \(course.id) was unsubscribed during sync; discarding results")
            syncProgress[course.id]?.state = .stale
            return nil
        }

        // Cancellation is safe before publication. Once SQLite starts the
        // synchronous commit, publish every part of the course or roll it all back.
        try Task.checkCancellation()

        let cursor = SyncCursor(
            courseID: course.id,
            siteID: site.id,
            lastSyncDate: Date(),
            lastModified: Date(),
            itemCount: allItems.count
        )
        try database.commitCourseSync(
            items: changes.added + changes.modified,
            deletingItemIDs: changes.removed.map(\.id),
            cursor: cursor,
            outline: CourseOutlineSnapshot(courseID: course.id, sections: sections)
        )

        syncProgress[course.id]?.processedItems = allItems.count
        syncProgress[course.id]?.state = .synced
        logger.info("Course \(course.id) sync complete: \(allItems.count) items")
        return cursor.lastSyncDate
    }

    /// Track downloads so database replacement can cancel and await them too.
    private func runPinnedDownloads(
        site: MoodleSite, token: AuthToken, courseIDs: Set<Int>
    ) async throws -> [Int: DiagnosticFailure] {
        if isStopping { throw CancellationError() }
        let task = Task { [self] in
            try await downloadPinnedItems(site: site, token: token, courseIDs: courseIDs)
        }
        pinnedDownloadTasks.insert(task)
        defer { pinnedDownloadTasks.remove(task) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Failed materializations remain retryable and make their course incomplete.
    private func downloadPinnedItems(
        site: MoodleSite, token: AuthToken, courseIDs: Set<Int>
    ) async throws -> [Int: DiagnosticFailure] {
        let pending = try database.fetchPinnedItems(siteID: site.id).filter {
            courseIDs.contains($0.courseID) && $0.syncState != .materialized
        }
        var failures: [Int: DiagnosticFailure] = [:]
        for item in pending {
            try Task.checkCancellation()
            guard item.remoteURL != nil else { continue }
            let pathExtension = (item.filename as NSString).pathExtension
            let baseName = item.id.replacingOccurrences(of: "/", with: "_")
            let tempFilename = pathExtension.isEmpty ? baseName : "\(baseName).\(pathExtension)"
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(tempFilename)
            do {
                try await downloadItem(itemID: item.id, site: site, token: token, destination: destination)
            } catch {
                if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
                if (error as? FindleError)?.requiresReauthentication == true { throw error }
                failures[item.courseID] = DiagnosticFailure(error)
            }
        }
        return failures
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
            items.append(contentsOf: fileItems(for: module, parentID: parentID, siteID: siteID, courseID: courseID))

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

            // Files from subfolders are kept flat under the folder item.
            items.append(contentsOf: fileItems(for: module, parentID: folderID, siteID: siteID, courseID: courseID))

        case .url:
            // Represent URL resources as .webloc files
            if let content = module.contents.first, let url = content.fileURL {
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
                    fileSize: Int64((try? MoodleWebLocation.data(for: url).count) ?? 0),
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

    /// Build the file items for a file or folder module.
    private func fileItems(
        for module: MoodleModule,
        parentID: String,
        siteID: String,
        courseID: Int
    ) -> [LocalItem] {
        let files = module.contents.filter { $0.type == "file" }
        let filenames = displayFilenames(for: files)

        return zip(files, filenames).map { content, filename in
            LocalItem(
                id: fileItemID(siteID: siteID, courseID: courseID, moduleID: module.id, content: content),
                parentID: parentID,
                siteID: siteID,
                courseID: courseID,
                remoteID: module.id,
                filename: filename,
                isDirectory: false,
                contentType: content.mimeType,
                fileSize: content.fileSize,
                creationDate: content.timeCreated,
                modificationDate: content.timeModified,
                syncState: .placeholder,
                remoteURL: content.fileURL,
                contentVersion: content.timeModified.map { String(Int($0.timeIntervalSince1970)) }
            )
        }
    }

    /// Item ID for a file inside a module. Root-level files keep the original ID so
    /// existing items aren't deleted and recreated. Files in a subdirectory include
    /// their path, so `a/index.html` and `b/index.html` don't share an ID.
    private func fileItemID(siteID: String, courseID: Int, moduleID: Int, content: MoodleFileContent) -> String {
        let base = "file-\(siteID)-\(courseID)-\(moduleID)"
        let subdirectories = (content.filePath ?? "").split(separator: "/")
        guard !subdirectories.isEmpty else {
            return "\(base)-\(content.fileName)"
        }
        return "\(base)-\(subdirectories.joined(separator: "_"))-\(content.fileName)"
    }

    /// Display names for the files of one module. When several files would share a
    /// filename (typically `index.html` in different subfolders), the ones inside a
    /// subfolder get the folder name appended, e.g. `index (b).html`.
    private func displayFilenames(for contents: [MoodleFileContent]) -> [String] {
        let sanitized = contents.map { FileNameSanitizer.sanitize($0.fileName, preserveExtension: true) }
        var counts: [String: Int] = [:]
        for name in sanitized {
            counts[name, default: 0] += 1
        }

        var used = Set<String>()
        return zip(contents, sanitized).map { content, name in
            var candidate = name
            if counts[name, default: 0] > 1,
               let folder = content.filePath?.split(separator: "/").last {
                candidate = suffixedFilename(name, suffix: FileNameSanitizer.sanitize(String(folder)))
            }

            // Last resort if the suffixed name still collides with another file.
            var unique = candidate
            var counter = 2
            while used.contains(unique) {
                unique = suffixedFilename(candidate, suffix: "\(counter)")
                counter += 1
            }
            used.insert(unique)
            return unique
        }
    }

    /// Insert ` (suffix)` before the file extension.
    private func suffixedFilename(_ filename: String, suffix: String) -> String {
        let stem = (filename as NSString).deletingPathExtension
        let pathExtension = (filename as NSString).pathExtension
        return pathExtension.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(pathExtension)"
    }

    // MARK: - Diffing

    private struct DiffResult {
        let added: [LocalItem]
        let modified: [LocalItem]
        let removed: [LocalItem]
    }

    private func diffItems(existing: [LocalItem], incoming: [LocalItem]) -> DiffResult {
        let existingByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { _, new in
            logger.warning("Dropping duplicate existing item id \(new.id, privacy: .private)")
            return new
        })
        let incomingByID = Dictionary(incoming.map { ($0.id, $0) }, uniquingKeysWith: { _, new in
            logger.warning("Dropping duplicate incoming item id \(new.id, privacy: .private)")
            return new
        })

        var added: [LocalItem] = []
        var modified: [LocalItem] = []
        var removed: [LocalItem] = []

        for (id, var item) in incomingByID {
            if let existing = existingByID[id] {
                // Preserve user-set metadata across syncs
                item.isPinned = existing.isPinned
                item.tagData = existing.tagData

                if existing.contentVersion != item.contentVersion ||
                   existing.fileSize != item.fileSize {
                    // Content changed: keep the placeholder reset so it re-downloads.
                    modified.append(item)
                } else if existing.filename != item.filename {
                    // Only the display name changed. Keep any materialized copy.
                    item.syncState = existing.syncState
                    item.localPath = existing.localPath
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
            throw FindleError.itemNotFound(itemID: itemID)
        }

        guard item.siteID == site.id, !item.isLocal, !item.isDirectory else {
            throw FindleError.downloadFailed(itemID: itemID, reason: "Item does not belong to this site's remote files")
        }

        guard let remoteURL = item.remoteURL else {
            throw FindleError.downloadFailed(itemID: itemID, reason: "No remote URL")
        }

        let localData = try MoodleWebLocation.data(for: item)
        if localData == nil {
            try AuthenticatedRequestOrigin(site: site).validate(remoteURL)
        }
        try Task.checkCancellation()
        guard try database.updateDownloadState(for: item, state: .downloading) != nil else {
            throw FindleError.itemNotFound(itemID: itemID)
        }

        do {
            if let localData {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try localData.write(to: destination, options: .atomic)
            } else {
                try await provider.downloadFile(url: remoteURL, site: site, token: token, destination: destination)
            }
            try Task.checkCancellation()
            guard try database.updateDownloadState(for: item, state: .materialized, localPath: destination.path) != nil else {
                throw FindleError.itemNotFound(itemID: itemID)
            }
            logger.info("Downloaded item \(itemID, privacy: .public)")
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: destination)
            _ = try? database.updateDownloadState(for: item, state: .placeholder, onlyIfDownloading: true)
            throw CancellationError()
        } catch {
            // Don't leave a half-written file behind for the next download to trip on.
            try? FileManager.default.removeItem(at: destination)
            do {
                _ = try database.updateDownloadState(for: item, state: .error, onlyIfDownloading: true)
            } catch let stateError {
                logger.error("Could not record download failure for \(itemID, privacy: .private): \(DiagnosticFailure(stateError).summary, privacy: .public)")
            }
            throw error
        }
    }

    // MARK: - Cancellation

    /// Cancel a course's in-flight sync and wait for it to finish, so callers can
    /// safely delete that course's items afterwards.
    public func cancelSync(courseID: Int) async {
        if let task = activeTasks[courseID] {
            task.cancel()
            _ = try? await task.value
            clearActiveTask(task, courseID: courseID)
        }
        syncProgress[courseID]?.state = .stale
    }

    public func cancelAllSyncs() {
        for (id, task) in activeTasks {
            task.cancel()
            syncProgress[id]?.state = .stale
        }
        activeTasks.removeAll()
        for task in pinnedDownloadTasks {
            task.cancel()
        }
    }

    /// Cancel and await every in-flight course and pinned-download task before
    /// callers replace or delete the database those tasks may still be writing.
    public func stopAllSyncs() async {
        isStopping = true
        let tasks = Array(activeTasks.values)
        let pinnedTasks = Array(pinnedDownloadTasks)
        for task in tasks { task.cancel() }
        for task in pinnedTasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
        for task in pinnedTasks { _ = try? await task.value }
        for id in activeTasks.keys {
            syncProgress[id]?.state = .stale
        }
        activeTasks.removeAll()
        isStopping = false
    }

    // MARK: - Progress

    public func progress(forCourse courseID: Int) -> SyncProgress? {
        syncProgress[courseID]
    }

    public func allProgress() -> [Int: SyncProgress] {
        syncProgress
    }
}
