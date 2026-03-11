import FileProvider
import SharedDomain
import FoodlePersistence
import OSLog

/// Enumerates items within a container (course folder, section folder, etc.).
final class ItemEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let database: Database
    private let logger = Logger(subsystem: "es.amodrono.foodle.file-provider", category: "Enumerator")

    init(containerIdentifier: NSFileProviderItemIdentifier, database: Database) {
        self.containerIdentifier = containerIdentifier
        self.database = database
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        logger.debug("Enumerating items for container: \(self.containerIdentifier.rawValue, privacy: .public)")

        do {
            let parentID: String?
            if containerIdentifier == .rootContainer {
                parentID = nil
            } else {
                parentID = containerIdentifier.rawValue
            }

            let items = try database.fetchItems(parentID: parentID)
            let providerItems = items.map { FileProviderItem(localItem: $0) }

            observer.didEnumerate(providerItems)
            observer.finishEnumerating(upTo: nil)
        } catch {
            logger.error("Enumeration failed: \(error.localizedDescription, privacy: .public)")
            observer.finishEnumeratingWithError(error)
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        // For incremental changes, re-enumerate all items in this container.
        // A production implementation would track changes and only send deltas.
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchorData = Data("\(Date().timeIntervalSince1970)".utf8)
        completionHandler(NSFileProviderSyncAnchor(anchorData))
    }
}

/// Enumerates the working set (recently accessed / important items).
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let database: Database
    private let logger = Logger(subsystem: "es.amodrono.foodle.file-provider", category: "WorkingSet")

    init(database: Database) {
        self.database = database
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        // Working set: return pinned and recently materialized items
        observer.didEnumerate([])
        observer.finishEnumerating(upTo: nil)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        completionHandler(NSFileProviderSyncAnchor(Data("0".utf8)))
    }
}
