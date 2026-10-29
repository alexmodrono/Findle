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
    private let logger = Logger(subsystem: "es.amodrono.findle", category: "SpotlightIndexer")

    static let shared = SpotlightIndexer()

    private init() {}

    private static func domainIdentifier(siteID: String, courseID: Int) -> String {
        "\(domainPrefix).course.\(siteID).\(courseID)"
    }

    // MARK: - Index After Sync

    func indexCourses(_ courses: [MoodleCourse], items: [LocalItem], siteName: String) {
        var searchableItems: [CSSearchableItem] = []
        var currentDomains = Set<String>()

        let itemsByCourseID = Dictionary(grouping: items, by: \.courseID)

        for course in courses where course.isSyncEnabled {
            searchableItems.append(makeSearchableItem(from: course, siteName: siteName))
            currentDomains.insert(Self.domainIdentifier(siteID: course.siteID, courseID: course.id))

            if let courseItems = itemsByCourseID[course.id] {
                for item in courseItems where !item.isDirectory {
                    searchableItems.append(
                        makeSearchableItem(from: item, courseName: course.fullName, siteName: siteName)
                    )
                }
            }
        }

        // Remove Spotlight entries for any course that was indexed previously
        // but is no longer enrolled or no longer has sync enabled. Without
        // this, dropped courses linger in Spotlight forever and clicking the
        // stale result deep-links to a course AppState no longer knows about.
        removeOrphans(currentDomains: currentDomains)

        guard !searchableItems.isEmpty else {
            persistIndexedDomains(currentDomains)
            return
        }

        let count = searchableItems.count
        let snapshot = currentDomains
        CSSearchableIndex.default().indexSearchableItems(searchableItems) { [logger, weak self] error in
            if let error {
                logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Indexed \(count) items in Spotlight")
                self?.persistIndexedDomains(snapshot)
            }
        }
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

    private func makeSearchableItem(from course: MoodleCourse, siteName: String) -> CSSearchableItem {
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

    private func makeSearchableItem(
        from item: LocalItem,
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
        attributes.contentDescription = "\(courseName) — \(siteName)"
        if item.fileSize > 0 { attributes.fileSize = NSNumber(value: item.fileSize) }
        attributes.contentCreationDate = item.creationDate
        attributes.contentModificationDate = item.modificationDate
        attributes.keywords = [courseName, siteName, "Moodle"]
        if let mimeType = item.contentType { attributes.contentType = mimeType }

        let uniqueID = "\(Self.domainPrefix).item.\(item.id)"
        let domainID = Self.domainIdentifier(siteID: item.siteID, courseID: item.courseID)

        return CSSearchableItem(
            uniqueIdentifier: uniqueID,
            domainIdentifier: domainID,
            attributeSet: attributes
        )
    }
}
