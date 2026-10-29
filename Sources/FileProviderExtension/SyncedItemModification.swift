import FileProvider
import SharedDomain
import FindlePersistence

/// Applies the metadata Findle owns without making unsupported timestamp
/// uploads a permanent sync failure for otherwise read-only Moodle items.
enum SyncedItemModification {
    struct Result {
        let item: FileProviderItem
        let stillPendingFields: NSFileProviderItemFields
    }

    static func apply(
        to localItem: LocalItem,
        changedFields: NSFileProviderItemFields,
        tagData: Data?,
        hasNewContents: Bool,
        siteID: String?,
        database: Database
    ) throws -> Result {
        let supportedRequestFields: NSFileProviderItemFields = [.tagData, .contentModificationDate]
        guard !hasNewContents, changedFields.subtracting(supportedRequestFields).isEmpty else {
            throw NSFileProviderError(.cannotSynchronize)
        }

        // macOS 12+ treats unchanged stillPendingFields as unsupported, rather
        // than parking the item with cannotSynchronize. Return a real item:
        // a nil successful result asks the system to delete it from disk.
        let pending = changedFields.intersection(.contentModificationDate)
        guard changedFields.contains(.tagData) else {
            return Result(item: FileProviderItem(localItem: localItem), stillPendingFields: pending)
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
        return Result(item: FileProviderItem(localItem: updated), stillPendingFields: pending)
    }
}
