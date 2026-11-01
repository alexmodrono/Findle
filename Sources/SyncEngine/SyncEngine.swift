// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import CryptoKit
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

    /// Sync a single course. Kept items are downloaded by the system, which
    /// reads their content policy from the File Provider extension.
    public func syncCourse(site: MoodleSite, token: AuthToken, course: MoodleCourse) async throws {
        _ = try await syncCourseTracked(site: site, token: token, course: course)
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

        let briefs = try await fetchAssignmentBriefs(site: site, token: token, course: course, sections: sections)

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
        var generatedContents: [String: Data] = [:]

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

            var sectionItems: [LocalItem] = []
            for module in section.modules {
                guard module.visible else { continue }
                if module.resourceType == .assignment {
                    let assignment = assignmentItems(for: module, brief: briefs[module.id], parentID: sectionItemID,
                                                     siteID: site.id, courseID: course.id)
                    sectionItems.append(contentsOf: assignment.items)
                    generatedContents.merge(assignment.generated) { _, new in new }
                    continue
                }
                let moduleItems = buildItems(
                    from: module,
                    parentID: sectionItemID,
                    siteID: site.id,
                    courseID: course.id,
                    token: token
                )
                sectionItems.append(contentsOf: moduleItems)
            }
            if let readme = labelReadme(for: section, siblings: sectionItems, parentID: sectionItemID,
                                        siteID: site.id, courseID: course.id) {
                sectionItems.append(readme.item)
                generatedContents[readme.item.id] = readme.data
            }
            allItems.append(contentsOf: sectionItems)
        }

        syncProgress[course.id]?.totalItems = allItems.count

        try Task.checkCancellation()

        // Diff against existing items. Scope the query to this course so the
        // `idx_items_course` index does the filtering — loading every row for
        // the site and filtering in memory made a full sync quadratic.
        let existingItems = try database.fetchItems(courseID: course.id, siteID: site.id).filter { !$0.isLocal }

        // An assignment without a brief (Moodle refused the request or left it
        // out) keeps what earlier syncs put in its folder instead of losing it.
        let built = Set(allItems.map(\.id))
        let foldersWithoutBrief = Set(allItems.filter { $0.id.hasPrefix("assign-") && briefs[$0.remoteID] == nil }.map(\.id))
        allItems += existingItems.filter { item in
            item.parentID.map(foldersWithoutBrief.contains) == true && !built.contains(item.id)
        }

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
        // The first sync of a course is its baseline: nothing in it is new.
        let arrivedItemIDs = existingItems.isEmpty ? [] : changes.arrived.map(\.id)
        try database.commitCourseSync(
            items: changes.added + changes.modified,
            deletingItemIDs: changes.removed.map(\.id),
            cursor: cursor,
            outline: CourseOutlineSnapshot(courseID: course.id, sections: sections),
            arrivedItemIDs: arrivedItemIDs,
            generatedContents: generatedContents
        )

        syncProgress[course.id]?.processedItems = allItems.count
        syncProgress[course.id]?.state = .synced
        logger.info("Course \(course.id) sync complete: \(allItems.count) items")
        return cursor.lastSyncDate
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

    // MARK: - Assignments and Labels

    /// Briefs keyed by course module, or none when the course has no assignments
    /// or Moodle refuses the request. Signing out still stops the sync.
    private func fetchAssignmentBriefs(
        site: MoodleSite, token: AuthToken, course: MoodleCourse, sections: [MoodleSection]
    ) async throws -> [Int: MoodleAssignmentBrief] {
        let hasAssignments = sections.contains { section in
            section.visible && section.modules.contains { $0.visible && $0.resourceType == .assignment }
        }
        guard hasAssignments else { return [:] }
        do {
            let briefs = try await provider.fetchAssignmentBriefs(site: site, token: token, courseID: course.id)
            return Dictionary(briefs.map { ($0.moduleID, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            if Self.isCancellation(error) || Task.isCancelled { throw CancellationError() }
            if (error as? FindleError)?.requiresReauthentication == true { throw error }
            logger.warning("Assignment briefs unavailable for course \(course.id, privacy: .public): \(DiagnosticFailure(error).summary, privacy: .public)")
            return [:]
        }
    }

    /// An assignment as a folder holding a README.md with its brief and the
    /// files attached to the brief.
    private func assignmentItems(
        for module: MoodleModule, brief: MoodleAssignmentBrief?, parentID: String, siteID: String, courseID: Int
    ) -> (items: [LocalItem], generated: [String: Data]) {
        let folderID = "assign-\(siteID)-\(courseID)-\(module.id)"
        let folder = LocalItem(
            id: folderID, parentID: parentID, siteID: siteID, courseID: courseID, remoteID: module.id,
            filename: FileNameSanitizer.sanitize(module.name), isDirectory: true, syncState: .materialized
        )
        guard let brief else { return ([folder], [:]) }

        let attachmentModule = MoodleModule(id: module.id, name: module.name, modName: module.modName,
                                            contents: brief.attachments)
        var items = [folder] + fileItems(for: attachmentModule, parentID: folderID, siteID: siteID, courseID: courseID)
        var generated: [String: Data] = [:]
        let text = Self.briefText(brief)
        if !text.isEmpty {
            let readme = Self.generatedFile(
                id: "brief-\(siteID)-\(courseID)-\(module.id)",
                filename: Self.readmeName(avoiding: items.filter { $0.parentID == folderID }),
                text: text, parentID: folderID, siteID: siteID, courseID: courseID, remoteID: module.id)
            items.append(readme.item)
            generated[readme.item.id] = readme.data
        }
        return (items, generated)
    }

    static func briefText(_ brief: MoodleAssignmentBrief) -> String {
        var parts: [String] = []
        if let dueDate = brief.dueDate {
            parts.append("Due " + dueDate.formatted(date: .long, time: .shortened))
        }
        if let intro = brief.intro.map(MoodleText.plainText(fromHTML:)), !intro.isEmpty {
            parts.append(intro)
        }
        guard !parts.isEmpty else { return "" }
        return (["# " + brief.name] + parts).joined(separator: "\n\n")
    }

    /// A README.md with the text of a section's labels, which otherwise only
    /// appear on the course page.
    private func labelReadme(
        for section: MoodleSection, siblings: [LocalItem], parentID: String, siteID: String, courseID: Int
    ) -> (item: LocalItem, data: Data)? {
        let texts = section.modules
            .filter { $0.visible && $0.resourceType == .label }
            .compactMap { $0.description.map(MoodleText.plainText(fromHTML:)) }
            .filter { !$0.isEmpty }
        guard !texts.isEmpty else { return nil }
        return Self.generatedFile(
            id: "readme-\(siteID)-\(courseID)-\(section.id)",
            filename: Self.readmeName(avoiding: siblings.filter { $0.parentID == parentID }),
            text: texts.joined(separator: "\n\n"), parentID: parentID, siteID: siteID, courseID: courseID,
            remoteID: section.id)
    }

    /// README.md, unless Moodle already has a file by that name in the folder.
    private static func readmeName(avoiding siblings: [LocalItem]) -> String {
        let taken = Set(siblings.map { $0.filename.lowercased() })
        return taken.contains("readme.md") ? "README (Findle).md" : "README.md"
    }

    /// A Markdown file whose bytes the sync stores. Its version is a digest of
    /// the text, so it only reads as changed when the text changes.
    private static func generatedFile(
        id: String, filename: String, text: String, parentID: String, siteID: String, courseID: Int, remoteID: Int
    ) -> (item: LocalItem, data: Data) {
        let data = Data((text + "\n").utf8)
        let digest = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let item = LocalItem(
            id: id, parentID: parentID, siteID: siteID, courseID: courseID, remoteID: remoteID,
            filename: filename, contentType: "net.daringfireball.markdown", fileSize: Int64(data.count),
            syncState: .placeholder, contentVersion: digest
        )
        return (item, data)
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
        /// Added items and items whose content changed; a rename alone doesn't count.
        let arrived: [LocalItem]
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
        var arrived: [LocalItem] = []

        for (id, var item) in incomingByID {
            if let existing = existingByID[id] {
                // Preserve user-set metadata across syncs
                item.isPinned = existing.isPinned
                item.tagData = existing.tagData

                if existing.contentVersion != item.contentVersion ||
                   existing.fileSize != item.fileSize {
                    // Content changed: keep the placeholder reset so it re-downloads.
                    modified.append(item)
                    arrived.append(item)
                } else if existing.filename != item.filename {
                    // Only the display name changed. Keep any materialized copy.
                    item.syncState = existing.syncState
                    item.localPath = existing.localPath
                    modified.append(item)
                }
            } else {
                added.append(item)
                arrived.append(item)
            }
        }

        for (id, item) in existingByID {
            if incomingByID[id] == nil {
                removed.append(item)
            }
        }

        return DiffResult(added: added, modified: modified, removed: removed, arrived: arrived)
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
    }

    /// Cancel and await every in-flight course task before callers replace or
    /// delete the database those tasks may still be writing.
    public func stopAllSyncs() async {
        isStopping = true
        let tasks = Array(activeTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = try? await task.value }
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
