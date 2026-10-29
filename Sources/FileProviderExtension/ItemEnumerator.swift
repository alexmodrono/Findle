// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import Foundation
import SharedDomain
import FindlePersistence
import OSLog

/// Sync anchors are opaque to the system, but we use them as a decimal-encoded
/// Int64 representing the database's monotonic change counter. Encoding as a
/// decimal string keeps them human-readable in logs while round-tripping
/// losslessly through `Data`.
enum SyncAnchorCoding {
    static func encode(_ value: Int64) -> NSFileProviderSyncAnchor {
        NSFileProviderSyncAnchor(Data(String(value).utf8))
    }

    static func decode(_ anchor: NSFileProviderSyncAnchor) throws -> Int64 {
        guard let s = String(data: anchor.rawValue, encoding: .utf8),
              !s.isEmpty, s.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(s), value >= 0 else {
            throw NSFileProviderError(.syncAnchorExpired)
        }
        return value
    }
}

/// Enumerates items within a container (course folder, section folder, etc.).
final class ItemEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let database: Database
    private let siteID: String?
    private let logger = Logger(subsystem: "es.amodrono.findle.file-provider", category: "Enumerator")

    init(containerIdentifier: NSFileProviderItemIdentifier, database: Database, siteID: String? = nil) {
        self.containerIdentifier = containerIdentifier
        self.database = database
        self.siteID = siteID
    }

    func invalidate() {}

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        logger.debug("Enumerating items for container: \(self.containerIdentifier.rawValue, privacy: .private)")

        do {
            guard let siteID, !siteID.isEmpty, try database.isSeedComplete() else { throw NSFileProviderError(.serverUnreachable) }
            let parentID: String?
            if containerIdentifier == .rootContainer {
                parentID = nil
            } else {
                parentID = containerIdentifier.rawValue
            }

            let items = try database.fetchItems(parentID: parentID, siteID: siteID)
            let providerItems = items.map { FileProviderItem(localItem: $0) }

            logger.debug("Enumerated \(providerItems.count, privacy: .public) items for \(self.containerIdentifier.rawValue, privacy: .private)")

            observer.didEnumerate(providerItems)
            observer.finishEnumerating(upTo: nil)
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .enumeration, outcome: .failed, failure: DiagnosticFailure(error)))
            logger.error("Enumeration failed: \(DiagnosticFailure(error).summary, privacy: .public)")
            observer.finishEnumeratingWithError(ProviderAccess.enumerationError(error))
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        logger.debug("Enumerating changes for container: \(self.containerIdentifier.rawValue, privacy: .private)")

        do {
            guard let siteID, !siteID.isEmpty, try database.isSeedComplete() else { throw NSFileProviderError(.serverUnreachable) }
            let parentID: String?
            if containerIdentifier == .rootContainer {
                parentID = nil
            } else {
                parentID = containerIdentifier.rawValue
            }

            let fromCounter = try SyncAnchorCoding.decode(anchor)
            let upperBound = try database.currentChangeCounter()
            guard fromCounter <= upperBound else { throw NSFileProviderError(.syncAnchorExpired) }
            // Only items whose updated_at exceeds the incoming anchor; the
            // trigger on writes guarantees updated_at is strictly increasing.
            let changedItems = try database.fetchItemsChangedSince(
                anchor: fromCounter, parentID: parentID, siteID: siteID, through: upperBound)
            let providerItems = changedItems.map { FileProviderItem(localItem: $0) }

            let deletedIDs = try database.fetchPendingDeletionsSince(anchor: fromCounter, siteID: siteID, through: upperBound)
            if !providerItems.isEmpty { observer.didUpdate(providerItems) }
            if !deletedIDs.isEmpty {
                let identifiers = deletedIDs.map { NSFileProviderItemIdentifier($0) }
                observer.didDeleteItems(withIdentifiers: identifiers)
            }

            observer.finishEnumeratingChanges(upTo: SyncAnchorCoding.encode(upperBound), moreComing: false)
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .enumeration, outcome: .failed, failure: DiagnosticFailure(error)))
            logger.error("Change enumeration failed: \(DiagnosticFailure(error).summary, privacy: .public)")
            observer.finishEnumeratingWithError(ProviderAccess.enumerationError(error))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        do {
            guard siteID?.isEmpty == false, try database.isSeedComplete() else { throw NSFileProviderError(.serverUnreachable) }
            completionHandler(SyncAnchorCoding.encode(try database.currentChangeCounter()))
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .enumeration, outcome: .failed, failure: DiagnosticFailure(error)))
            completionHandler(nil)
        }
    }
}

/// Enumerates the working set — all items in the domain that the system should track.
final class WorkingSetEnumerator: NSObject, NSFileProviderEnumerator {
    private let database: Database
    private let siteID: String?
    private let logger = Logger(subsystem: "es.amodrono.findle.file-provider", category: "WorkingSet")

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
            guard let siteID, !siteID.isEmpty, try database.isSeedComplete() else { throw NSFileProviderError(.serverUnreachable) }
            let items = try database.fetchAllItems(siteID: siteID)

            let providerItems = items.map { FileProviderItem(localItem: $0) }
            logger.debug("Working set: \(providerItems.count, privacy: .public) items")

            observer.didEnumerate(providerItems)
            observer.finishEnumerating(upTo: nil)
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .enumeration, outcome: .failed, failure: DiagnosticFailure(error)))
            logger.error("Working set enumeration failed: \(DiagnosticFailure(error).summary, privacy: .public)")
            observer.finishEnumeratingWithError(ProviderAccess.enumerationError(error))
        }
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from anchor: NSFileProviderSyncAnchor
    ) {
        do {
            guard let siteID, !siteID.isEmpty, try database.isSeedComplete() else { throw NSFileProviderError(.serverUnreachable) }
            let fromCounter = try SyncAnchorCoding.decode(anchor)
            let upperBound = try database.currentChangeCounter()
            guard fromCounter <= upperBound else { throw NSFileProviderError(.syncAnchorExpired) }
            let changedItems = try database.fetchItemsChangedSince(anchor: fromCounter, siteID: siteID, through: upperBound)

            let providerItems = changedItems.map { FileProviderItem(localItem: $0) }

            let deletedIDs = try database.fetchPendingDeletionsSince(anchor: fromCounter, siteID: siteID, through: upperBound)
            if !providerItems.isEmpty { observer.didUpdate(providerItems) }
            if !deletedIDs.isEmpty {
                let identifiers = deletedIDs.map { NSFileProviderItemIdentifier($0) }
                observer.didDeleteItems(withIdentifiers: identifiers)
            }

            observer.finishEnumeratingChanges(upTo: SyncAnchorCoding.encode(upperBound), moreComing: false)
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .enumeration, outcome: .failed, failure: DiagnosticFailure(error)))
            observer.finishEnumeratingWithError(ProviderAccess.enumerationError(error))
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        do {
            guard siteID?.isEmpty == false, try database.isSeedComplete() else { throw NSFileProviderError(.serverUnreachable) }
            completionHandler(SyncAnchorCoding.encode(try database.currentChangeCounter()))
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .enumeration, outcome: .failed, failure: DiagnosticFailure(error)))
            completionHandler(nil)
        }
    }
}
