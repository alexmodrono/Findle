import FileProvider
import SharedDomain
import FindlePersistence

/// Applies the metadata Findle owns without making unsupported timestamp
/// uploads a permanent sync failure for otherwise read-only Moodle items.
enum SyncedItemModification {
    struct Result {
        let item: FileProviderItem
        let stillPendingFields: NSFileProviderItemFields
        /// Opening changed the badges of other items (its folder, its contents),
        /// so Finder needs to hear about them.
        var badgesChanged = false
    }

    static func apply(
        to localItem: LocalItem,
        changedFields: NSFileProviderItemFields,
        tagData: Data?,
        lastUsedDate: Date? = nil,
        hasNewContents: Bool,
        siteID: String?,
        database: Database
    ) throws -> Result {
        let supportedRequestFields: NSFileProviderItemFields = [.tagData, .contentModificationDate, .lastUsedDate, .extendedAttributes]
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
        guard changedFields.contains(.tagData) else {
            return Result(item: FileProviderItem(localItem: localItem, lastUsedDate: openedAt), stillPendingFields: pending,
                          badgesChanged: badgesChanged)
        }

        let parts = localItem.id.split(separator: "-")
        if parts.first == "course", let courseID = parts.last.flatMap({ Int($0) }), let siteID {
            let tags = tagData.map { FinderTag.parseTags(from: $0) } ?? []
            try database.saveCourseTags(tags, courseID: courseID, siteID: siteID)
            try database.updateItemTagData(id: localItem.id, tagData: FinderTag.tagData(from: tags))
        } else {
            try database.updateItemTagData(id: localItem.id, tagData: tagData)
        }
        guard let updated = try database.fetchItem(id: localItem.id) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return Result(item: FileProviderItem(localItem: updated, lastUsedDate: openedAt), stillPendingFields: pending,
                      badgesChanged: badgesChanged)
    }
}
