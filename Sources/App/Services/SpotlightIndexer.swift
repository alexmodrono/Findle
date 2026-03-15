import CoreSpotlight
import UniformTypeIdentifiers
import SharedDomain
import FoodlePersistence
import OSLog

/// Indexes Moodle courses and files into CoreSpotlight for system-wide search.
final class SpotlightIndexer: @unchecked Sendable {
    private static let domainPrefix = "es.amodrono.foodle"
    private let logger = Logger(subsystem: "es.amodrono.foodle", category: "SpotlightIndexer")

    static let shared = SpotlightIndexer()

    private init() {}

    // MARK: - Index After Sync

    func indexCourses(_ courses: [MoodleCourse], items: [LocalItem], siteName: String) {
        var searchableItems: [CSSearchableItem] = []

        let itemsByCourseID = Dictionary(grouping: items, by: \.courseID)

        for course in courses where course.isSyncEnabled {
            searchableItems.append(makeSearchableItem(from: course, siteName: siteName))

            if let courseItems = itemsByCourseID[course.id] {
                for item in courseItems where !item.isDirectory {
                    searchableItems.append(
                        makeSearchableItem(from: item, courseName: course.fullName, siteName: siteName)
                    )
                }
            }
        }

        guard !searchableItems.isEmpty else { return }

        let count = searchableItems.count
        CSSearchableIndex.default().indexSearchableItems(searchableItems) { [logger] error in
            if let error {
                logger.error("Spotlight indexing failed: \(error.localizedDescription, privacy: .public)")
            } else {
                logger.info("Indexed \(count) items in Spotlight")
            }
        }
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
    }

    func removeItems(forCourse courseID: Int, siteID: String) {
        let groupID = "\(Self.domainPrefix).course.\(siteID).\(courseID)"
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [groupID]) { [logger] error in
            if let error {
                logger.error("Failed to remove Spotlight items for course \(courseID): \(error.localizedDescription, privacy: .public)")
            }
        }
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

        let uniqueID = "\(Self.domainPrefix).course.\(course.siteID).\(course.id)"
        let domainID = "\(Self.domainPrefix).course.\(course.siteID).\(course.id)"

        return CSSearchableItem(
            uniqueIdentifier: uniqueID,
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
        let domainID = "\(Self.domainPrefix).course.\(item.siteID).\(item.courseID)"

        return CSSearchableItem(
            uniqueIdentifier: uniqueID,
            domainIdentifier: domainID,
            attributeSet: attributes
        )
    }
}
