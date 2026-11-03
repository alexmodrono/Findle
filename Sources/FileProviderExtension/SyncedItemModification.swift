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
        /// Opening changed the badges of other items (its folder, its contents),
        /// so Finder needs to hear about them.
        var badgesChanged = false
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
        lastUsedDate: Date? = nil,
        hasNewContents: Bool,
        siteID: String?,
        database: Database
    ) throws -> Result {
        var supportedRequestFields: NSFileProviderItemFields = [.tagData, .contentModificationDate, .lastUsedDate, .extendedAttributes]
        if localItem.isCourseRoot {
            supportedRequestFields.insert(.filename)
        }
        guard !hasNewContents, changedFields.subtracting(supportedRequestFields).isEmpty else {
            throw NSFileProviderError(.cannotSynchronize)
        }

        // The system reports when the user opens an item. Opening a folder
        // shows its contents, so both end what counts as new (FI-04).
        var openedAt: Date?
        var localItem = localItem
        var badgesChanged = false
        if changedFields.contains(.lastUsedDate), let lastUsedDate {
            badgesChanged = try database.markItemOpened(id: localItem.id, at: lastUsedDate)
            openedAt = lastUsedDate
            if badgesChanged, let reread = try database.fetchItem(id: localItem.id) {
                localItem = reread
            }
        }

        // macOS 12+ treats unchanged stillPendingFields as unsupported, rather
        // than parking the item with cannotSynchronize. Return a real item:
        // a nil successful result asks the system to delete it from disk.
        // Findle owns the extended attributes of Moodle items ("Where from",
        // author), so edits to them settle like timestamp uploads: no write, no error.
        let pending = changedFields.intersection([.contentModificationDate, .extendedAttributes])
        guard !changedFields.isDisjoint(with: [.tagData, .filename]) else {
            return Result(item: FileProviderItem(localItem: localItem, lastUsedDate: openedAt), stillPendingFields: pending,
                          badgesChanged: badgesChanged)
        }

        if changedFields.contains(.filename) {
            guard let filename else { throw NSFileProviderError(.cannotSynchronize) }
            try renameCourseRoot(localItem, to: filename, database: database)
        }

        if changedFields.contains(.tagData) {
            let parts = localItem.id.split(separator: "-")
            if parts.first == "course", let courseID = parts.last.flatMap({ Int($0) }), let siteID {
                // One transaction keeps the course's tag list and the root's
                // Finder tags in step.
                let tags = tagData.map { FinderTag.parseTags(from: $0) } ?? []
                try database.setCourseTags(tags, courseID: courseID, siteID: siteID)
            } else {
                try database.updateItemTagData(id: localItem.id, tagData: tagData)
            }
        }

        guard let updated = try database.fetchItem(id: localItem.id) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return Result(item: FileProviderItem(localItem: updated, lastUsedDate: openedAt), stillPendingFields: pending,
                      badgesChanged: badgesChanged)
    }

    /// Store a Finder rename of a course folder as the course's custom name.
    ///
    /// The root keeps the sanitized form, which is what the system gets back,
    /// so Finder shows exactly the name later syncs will keep. Renaming the
    /// folder back to the Moodle name clears the custom name. A name that
    /// would land on another course's folder (case-insensitively, after
    /// sanitizing) is rejected as a collision without changing anything;
    /// `Database.renameCourse` makes that check inside its write transaction.
    private static func renameCourseRoot(_ courseRoot: LocalItem, to proposedName: String, database: Database) throws {
        guard let course = try database.fetchCourse(id: courseRoot.courseID, siteID: courseRoot.siteID) else {
            throw NSFileProviderError(.noSuchItem)
        }
        do {
            try database.renameCourse(
                courseID: course.id,
                siteID: course.siteID,
                customName: course.normalizedCustomName(proposedName)
            )
        } catch is CourseFolderNameConflictError {
            throw NSFileProviderError(.filenameCollision)
        }
    }
}
