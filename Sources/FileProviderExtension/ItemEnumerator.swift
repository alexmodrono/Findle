// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

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

            let items = try database.fetchItems(parentID: parentID)
            let providerItems = items.map { FileProviderItem(localItem: $0) }

            if !providerItems.isEmpty {
                observer.didUpdate(providerItems)
            }

            let deletedIDs = try database.fetchPendingDeletions()
            if !deletedIDs.isEmpty {
                let identifiers = deletedIDs.map { NSFileProviderItemIdentifier($0) }
                observer.didDeleteItems(withIdentifiers: identifiers)
            }

            let newAnchor = NSFileProviderSyncAnchor(Data("\(Date().timeIntervalSince1970)".utf8))
            observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
        } catch {
            logger.error("Change enumeration failed: \(error.localizedDescription, privacy: .public)")
            observer.finishEnumeratingWithError(error)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchorData = Data("\(Date().timeIntervalSince1970)".utf8)
        completionHandler(NSFileProviderSyncAnchor(anchorData))
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
            let items: [LocalItem]
            if let siteID {
                items = try database.fetchAllItems(siteID: siteID)
            } else {
                items = try database.fetchItems(parentID: nil)
            }

            let providerItems = items.map { FileProviderItem(localItem: $0) }

            if !providerItems.isEmpty {
                observer.didUpdate(providerItems)
            }

            let deletedIDs = try database.fetchPendingDeletions()
            if !deletedIDs.isEmpty {
                let identifiers = deletedIDs.map { NSFileProviderItemIdentifier($0) }
                observer.didDeleteItems(withIdentifiers: identifiers)
            }

            let newAnchor = NSFileProviderSyncAnchor(Data("\(Date().timeIntervalSince1970)".utf8))
            observer.finishEnumeratingChanges(upTo: newAnchor, moreComing: false)
        } catch {
            observer.finishEnumeratingWithError(error)
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        let anchorData = Data("\(Date().timeIntervalSince1970)".utf8)
        completionHandler(NSFileProviderSyncAnchor(anchorData))
    }
}
