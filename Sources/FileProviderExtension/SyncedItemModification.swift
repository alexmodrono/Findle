import FileProvider
import SharedDomain
import FindlePersistence

/// Applies the metadata Findle owns without making unsupported timestamp
/// uploads a permanent sync failure for otherwise read-only Moodle items.
///
/// Findle owns tags on every synced item, and the name of course root
/// folders (stored as the course's custom name).
enum SyncedItemModification {
    struct Result {
        let item: FileProviderItem
        let stillPendingFields: NSFileProviderItemFields
    }

    /// Apply a Finder edit to a synced item. Tag edits are stored for any item
    /// and a filename edit renames a course root; content, moves, and other
    /// fields throw `cannotSynchronize`. Timestamp-only changes are reported
    /// back as still pending instead of failing.
    static func apply(
        to localItem: LocalItem,
        changedFields: NSFileProviderItemFields,
        tagData: Data?,
        filename: String? = nil,
        hasNewContents: Bool,
        siteID: String?,
        database: Database
    ) throws -> Result {
        var supportedRequestFields: NSFileProviderItemFields = [.tagData, .contentModificationDate]
        if localItem.isCourseRoot {
            supportedRequestFields.insert(.filename)
        }
        guard !hasNewContents, changedFields.subtracting(supportedRequestFields).isEmpty else {
            throw NSFileProviderError(.cannotSynchronize)
        }

        // macOS 12+ treats unchanged stillPendingFields as unsupported, rather
        // than parking the item with cannotSynchronize. Return a real item:
        // a nil successful result asks the system to delete it from disk.
        let pending = changedFields.intersection(.contentModificationDate)
        guard !changedFields.isDisjoint(with: [.tagData, .filename]) else {
            return Result(item: FileProviderItem(localItem: localItem), stillPendingFields: pending)
        }

        if changedFields.contains(.filename) {
            guard let filename else { throw NSFileProviderError(.cannotSynchronize) }
            try renameCourseRoot(localItem, to: filename, database: database)
        }
        guard changedFields.contains(.tagData) else {
            return try updatedResult(for: localItem, pending: pending, database: database)
        }

        let parts = localItem.id.split(separator: "-")
        if parts.first == "course", let courseID = parts.last.flatMap({ Int($0) }), let siteID {
            let tags = tagData.map { FinderTag.parseTags(from: $0) } ?? []
            try database.saveCourseTags(tags, courseID: courseID, siteID: siteID)
            try database.updateItemTagData(id: localItem.id, tagData: FinderTag.tagData(from: tags))
        } else {
            try database.updateItemTagData(id: localItem.id, tagData: tagData)
        }
        return try updatedResult(for: localItem, pending: pending, database: database)
    }

    /// The item as now stored, with `pending` fields left for the system.
    private static func updatedResult(
        for localItem: LocalItem,
        pending: NSFileProviderItemFields,
        database: Database
    ) throws -> Result {
        guard let updated = try database.fetchItem(id: localItem.id) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return Result(item: FileProviderItem(localItem: updated), stillPendingFields: pending)
    }

    /// Store a Finder rename of a course folder as the course's custom name.
    ///
    /// The root keeps the sanitized form, which is what the system gets back,
    /// so Finder shows exactly the name later syncs will keep. Renaming the
    /// folder back to the Moodle name clears the custom name. A name that
    /// would land on another course's folder (case-insensitively, after
    /// sanitizing) is rejected as a collision without changing anything.
    private static func renameCourseRoot(_ courseRoot: LocalItem, to proposedName: String, database: Database) throws {
        let courses = try database.fetchCourses(siteID: courseRoot.siteID)
        guard let course = courses.first(where: { $0.id == courseRoot.courseID }) else {
            throw NSFileProviderError(.noSuchItem)
        }
        guard course.folderNameConflict(forProposedName: proposedName, among: courses) == nil else {
            throw NSFileProviderError(.filenameCollision)
        }
        try database.renameCourse(
            courseID: course.id,
            siteID: course.siteID,
            customName: course.normalizedCustomName(proposedName)
        )
    }
}
