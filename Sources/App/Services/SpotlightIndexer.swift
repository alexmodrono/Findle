// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import CoreSpotlight
import UniformTypeIdentifiers
import SharedDomain
import FindlePersistence
import OSLog

/// Indexes Moodle courses and files into CoreSpotlight for system-wide search.
final class SpotlightIndexer: @unchecked Sendable {
    private static let domainPrefix = BundleIdentifiers.spotlightPrefix
    private static let lastIndexedDomainsKey = "spotlightLastIndexedDomains"
    private let logger = Logger(subsystem: "com.amodrono.findle", category: "SpotlightIndexer")

    static let shared = SpotlightIndexer()

    private init() {}

    private static func domainIdentifier(siteID: String, courseID: Int) -> String {
        "\(domainPrefix).course.\(siteID).\(courseID)"
    }

    // MARK: - Index After Sync

    /// What a Spotlight result names, decoded from its identifier.
    enum Result: Equatable {
        case course(Int)
        /// A file or an assignment's folder, revealed in Finder.
        case item(String)
        /// A quiz, opened in Moodle.
        case quiz(Int)
    }

    static func result(for identifier: String) -> Result? {
        let prefix = domainPrefix + "."
        guard identifier.hasPrefix(prefix) else { return nil }
        let rest = identifier.dropFirst(prefix.count)
        if rest.hasPrefix("course.") { return rest.split(separator: ".").last.flatMap { Int($0) }.map(Result.course) }
        if rest.hasPrefix("item.") { return .item(String(rest.dropFirst("item.".count))) }
        if rest.hasPrefix("quiz.") { return rest.split(separator: ".").last.flatMap { Int($0) }.map(Result.quiz) }
        return nil
    }

    /// Re-indexes each synced course: the course, its files and assignments
    /// with the section they sit in, and its quizzes. Each course's entries are
    /// replaced, so files Moodle removed leave the index.
    func indexCourses(_ courses: [MoodleCourse], items: [LocalItem], assignments: [MoodleAssignment] = [],
                      quizzes: [MoodleQuiz] = [], siteName: String) {
        let synced = courses.filter(\.isSyncEnabled)
        let currentDomains = Set(synced.map { Self.domainIdentifier(siteID: $0.siteID, courseID: $0.id) })

        // Remove Spotlight entries for any course that was indexed previously
        // but is no longer enrolled or no longer has sync enabled. Without
        // this, dropped courses linger in Spotlight forever and clicking the
        // stale result deep-links to a course AppState no longer knows about.
        removeOrphans(currentDomains: currentDomains)

        let searchableItems = Self.searchableItems(courses: synced, items: items, assignments: assignments,
                                                   quizzes: quizzes, siteName: siteName)
        guard !searchableItems.isEmpty else {
            persistIndexedDomains(currentDomains)
            return
        }

        let count = searchableItems.count
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: Array(currentDomains)) { [logger, weak self] error in
            if let error {
                logger.error("Could not clear courses before re-indexing: \(error.localizedDescription, privacy: .public)")
            }
            index.indexSearchableItems(searchableItems) { error in
                if let error {
                    logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
                } else {
                    logger.info("Indexed \(count) items in Spotlight")
                    self?.persistIndexedDomains(currentDomains)
                }
            }
        }
    }

    /// The entries for `courses`, which must be the synced ones.
    static func searchableItems(courses: [MoodleCourse], items: [LocalItem], assignments: [MoodleAssignment],
                                quizzes: [MoodleQuiz], siteName: String) -> [CSSearchableItem] {
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let itemsByCourse = Dictionary(grouping: items, by: \.courseID)
        let assignmentsByModule = Dictionary(assignments.compactMap { a in a.moduleID.map { ("\(a.courseID)-\($0)", a) } },
                                             uniquingKeysWith: { first, _ in first })
        var result: [CSSearchableItem] = []
        for course in courses {
            result.append(searchableItem(from: course, siteName: siteName))
            for item in itemsByCourse[course.id] ?? [] where item.siteID == course.siteID {
                let place = Self.place(of: item, in: byID)
                if !item.isDirectory {
                    result.append(searchableItem(from: item, place: place, courseName: course.fullName, siteName: siteName))
                } else if item.id.hasPrefix("assign-") {
                    result.append(searchableAssignment(item, assignment: assignmentsByModule["\(course.id)-\(item.remoteID)"],
                                                       place: place, courseName: course.fullName, siteName: siteName))
                }
            }
            for quiz in quizzes where quiz.courseID == course.id {
                result.append(searchableQuiz(quiz, siteID: course.siteID, courseName: course.fullName, siteName: siteName))
            }
        }
        return result
    }

    /// The folders between the course and `item`, outermost first.
    static func place(of item: LocalItem, in byID: [String: LocalItem]) -> [String] {
        var names: [String] = []
        var next = item.parentID
        while let id = next, names.count < 32, let parent = byID[id], !parent.id.hasPrefix("course-") {
            names.insert(parent.filename, at: 0)
            next = parent.parentID
        }
        return names
    }

    private static func describe(_ place: [String], courseName: String, siteName: String) -> String {
        (place + [courseName]).joined(separator: " › ") + " — " + siteName
    }

    private func removeOrphans(currentDomains: Set<String>) {
        let previous = loadIndexedDomains()
        let orphans = previous.subtracting(currentDomains)
        guard !orphans.isEmpty else { return }

        let orphanList = Array(orphans)
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: orphanList) { [logger] error in
            if let error {
                logger.error("Failed to remove orphaned Spotlight domains: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Removed \(orphanList.count) orphaned Spotlight course domain(s)")
            }
        }
    }

    private func loadIndexedDomains() -> Set<String> {
        let raw = UserDefaults.standard.stringArray(forKey: Self.lastIndexedDomainsKey) ?? []
        return Set(raw)
    }

    private func persistIndexedDomains(_ domains: Set<String>) {
        UserDefaults.standard.set(Array(domains), forKey: Self.lastIndexedDomainsKey)
    }

    // MARK: - Remove

    func removeAllItems() {
        CSSearchableIndex.default().deleteAllSearchableItems { [logger] error in
            if let error {
                logger.error("Failed to clear Spotlight index: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Cleared Spotlight index")
            }
        }
        // Wipe the snapshot so the next indexCourses call doesn't think there
        // are orphans to delete from an empty index.
        UserDefaults.standard.removeObject(forKey: Self.lastIndexedDomainsKey)
    }

    func removeItems(forCourse courseID: Int, siteID: String) {
        let groupID = Self.domainIdentifier(siteID: siteID, courseID: courseID)
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [groupID]) { [logger] error in
            if let error {
                logger.error("Failed to remove Spotlight items for course \(courseID): \(error.localizedDescription, privacy: .public)")
            }
        }
        // Forget this course from the snapshot so it isn't double-removed
        // as an orphan on the next indexCourses pass.
        var snapshot = loadIndexedDomains()
        snapshot.remove(groupID)
        persistIndexedDomains(snapshot)
    }

    // MARK: - Item Construction

    private static func searchableItem(from course: MoodleCourse, siteName: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .folder)
        attributes.title = course.fullName
        attributes.contentDescription = course.summary
        attributes.displayName = course.fullName
        attributes.alternateNames = [course.shortName]
        if let start = course.startDate { attributes.startDate = start }
        if let end = course.endDate { attributes.endDate = end }
        attributes.keywords = [course.shortName, siteName, "Moodle", "course"]

        let domainID = Self.domainIdentifier(siteID: course.siteID, courseID: course.id)

        return CSSearchableItem(
            uniqueIdentifier: domainID,
            domainIdentifier: domainID,
            attributeSet: attributes
        )
    }

    private static func searchableItem(
        from item: LocalItem,
        place: [String],
        courseName: String,
        siteName: String
    ) -> CSSearchableItem {
        let contentType: UTType = {
            if let mimeType = item.contentType {
                return UTType(mimeType: mimeType) ?? UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data
            }
            return UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data
        }()

        let attributes = CSSearchableItemAttributeSet(contentType: contentType)
        attributes.title = item.filename
        attributes.displayName = item.filename
        attributes.contentDescription = describe(place, courseName: courseName, siteName: siteName)
        if item.fileSize > 0 { attributes.fileSize = NSNumber(value: item.fileSize) }
        attributes.contentCreationDate = item.creationDate
        attributes.contentModificationDate = item.modificationDate
        attributes.keywords = place + [courseName, siteName, "Moodle"]
        if let author = item.author { attributes.authorNames = [author] }
        if let mimeType = item.contentType { attributes.contentType = mimeType }

        return CSSearchableItem(
            uniqueIdentifier: "\(Self.domainPrefix).item.\(item.id)",
            domainIdentifier: Self.domainIdentifier(siteID: item.siteID, courseID: item.courseID),
            attributeSet: attributes
        )
    }

    private static func searchableAssignment(
        _ folder: LocalItem, assignment: MoodleAssignment?, place: [String], courseName: String, siteName: String
    ) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .folder)
        attributes.title = folder.filename
        attributes.displayName = folder.filename
        var description = "Assignment"
        if let due = assignment?.dueDate {
            description += " · Due " + due.formatted(date: .abbreviated, time: .shortened)
            attributes.dueDate = due
        }
        attributes.contentDescription = description + " · " + describe(place, courseName: courseName, siteName: siteName)
        attributes.keywords = place + [courseName, siteName, "Moodle", "assignment"]
        return CSSearchableItem(
            uniqueIdentifier: "\(Self.domainPrefix).item.\(folder.id)",
            domainIdentifier: Self.domainIdentifier(siteID: folder.siteID, courseID: folder.courseID),
            attributeSet: attributes
        )
    }

    private static func searchableQuiz(_ quiz: MoodleQuiz, siteID: String, courseName: String, siteName: String) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        attributes.title = quiz.name
        attributes.displayName = quiz.name
        var description = "Quiz"
        if let close = quiz.closeDate {
            description += " · Closes " + close.formatted(date: .abbreviated, time: .shortened)
            attributes.dueDate = close
        }
        attributes.contentDescription = description + " · " + describe([], courseName: courseName, siteName: siteName)
        attributes.keywords = [courseName, siteName, "Moodle", "quiz"]
        return CSSearchableItem(
            uniqueIdentifier: "\(Self.domainPrefix).quiz.\(siteID).\(quiz.id)",
            domainIdentifier: Self.domainIdentifier(siteID: siteID, courseID: quiz.courseID),
            attributeSet: attributes
        )
    }
}
