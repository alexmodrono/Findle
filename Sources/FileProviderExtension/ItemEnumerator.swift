// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import Foundation
import SharedDomain
import FoodlePersistence
import OSLog

/// Sync anchors are opaque to the system, but we use them as a decimal-encoded
/// Int64 representing the database's monotonic change counter. Encoding as a
/// decimal string keeps them human-readable in logs while round-tripping
/// losslessly through `Data`.
enum SyncAnchorCoding {
    static func encode(_ value: Int64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(value).utf8))
    }

    static func decode(_ anchor: NSFileProviderSyncAnchor) -> Int64 {
        guard let s = String(data: anchor.rawValue, encoding: .utf8),
              let value = Int64(s) else {
            return 0
        }
        return value
    }
}

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

            logger.debug("Enumerated \(providerItems.count, privacy: .public) items for \(self.containerIdentifier.rawValue, privacy: .public)")

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
        logger.debug("Enumerating changes for container: \(self.containerIdentifier.rawValue, privacy: .public)")

        do {
            let parentID: String?
            if containerIdentifier == .rootContainer {
                parentID = nil
            } else {
                parentID = containerIdentifier.rawValue
            }

            let fromCounter = SyncAnchorCoding.decode(anchor)
            // Only items whose updated_at exceeds the incoming anchor; the
            // trigger on writes guarantees updated_at is strictly increasing.
            let changedItems = try database.fetchItemsChangedSince(anchor: fromCounter, parentID: parentID)
            let providerItems = changedItems.map { FileProviderItem(localItem: $0) }

            if !providerItems.isEmpty {
                observer.didUpdate(providerItems)
            }

            let deletedIDs = try database.fetchPendingDeletionsSince(anchor: fromCounter)
            if !deletedIDs.isEmpty {
                let identifiers = deletedIDs.map { NSFileProviderItemIdentifier($0) }
                observer.didDeleteItems(withIdentifiers: identifiers)
            }

            let newCounter = try database.currentChangeCounter()
            observer.finishEnumeratingChanges(upTo: SyncAnchorCoding.encode(newCounter), moreComing: false)
        } catch {
            logger.error("Change enumeration failed: \(error.localizedDescription, privacy: .public)")
            observer.finishEnumeratingWithError(error)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let counter = (try? database.currentChangeCounter()) ?? 0
        completionHandler(SyncAnchorCoding.encode(counter))
    }
}

/// Enumerates the working set — all items in the domain that the system should track.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let database: Database
    private let siteID: String?
    private let logger = Logger(subsystem: "es.amodrono.foodle.file-provider", category: "WorkingSet")

    init(database: Database, siteID: String? = nil) {
        self.database = database
        self.siteID = siteID
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        logger.debug("Enumerating working set")

        do {
            let items: [LocalItem]
            if let siteID {
                items = try database.fetchAllItems(siteID: siteID)
            } else {
                // Fall back to root items if siteID unknown
                items = try database.fetchItems(parentID: nil)
            }

            let providerItems = items.map { FileProviderItem(localItem: $0) }
            logger.debug("Working set: \(providerItems.count, privacy: .public) items")

            observer.didEnumerate(providerItems)
            observer.finishEnumerating(upTo: nil)
        } catch {
            logger.error("Working set enumeration failed: \(error.localizedDescription, privacy: .public)")
            observer.finishEnumeratingWithError(error)
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        do {
            let fromCounter = SyncAnchorCoding.decode(anchor)
            let changedItems: [LocalItem]
            if let siteID {
                changedItems = try database.fetchItemsChangedSince(anchor: fromCounter, siteID: siteID)
            } else {
                changedItems = try database.fetchItemsChangedSince(anchor: fromCounter, parentID: nil)
            }

            let providerItems = changedItems.map { FileProviderItem(localItem: $0) }

            if !providerItems.isEmpty {
                observer.didUpdate(providerItems)
            }

            let deletedIDs = try database.fetchPendingDeletionsSince(anchor: fromCounter)
            if !deletedIDs.isEmpty {
                let identifiers = deletedIDs.map { NSFileProviderItemIdentifier($0) }
                observer.didDeleteItems(withIdentifiers: identifiers)
            }

            let newCounter = try database.currentChangeCounter()
            observer.finishEnumeratingChanges(upTo: SyncAnchorCoding.encode(newCounter), moreComing: false)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let counter = (try? database.currentChangeCounter()) ?? 0
        completionHandler(SyncAnchorCoding.encode(counter))
    }
}
