// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import CryptoKit
import FileProvider
import UniformTypeIdentifiers
import SharedDomain

/// Whether `item` is a file or folder the user created in the personal files store.
/// Stand-ins are `local-`-less rows that recreate Moodle folders, so they are excluded.
func isUserItem(_ item: LocalItem) -> Bool {
    item.isLocal && item.id.hasPrefix("local-")
}

/// Whether `item` can hold children, whichever kind of directory it is.
func isContainer(_ item: LocalItem) -> Bool {
    item.isDirectory
}

/// Adapts a LocalItem to NSFileProviderItem for the File Provider framework.
final class FileProviderItem: NSObject, NSFileProviderItem {
    private let localItem: LocalItem
    private let openedAt: Date?

    /// `lastUsedDate` echoes a date the system just reported, so its replica keeps it.
    init(localItem: LocalItem, lastUsedDate: Date? = nil) {
        self.localItem = localItem
        self.openedAt = lastUsedDate
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(localItem.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if let parentID = localItem.parentID {
            return NSFileProviderItemIdentifier(parentID)
        }
        return .rootContainer
    }

    var capabilities: NSFileProviderItemCapabilities {
        if isUserItem(localItem) {
            var caps: NSFileProviderItemCapabilities = [
                .allowsReading, .allowsWriting, .allowsRenaming,
                .allowsReparenting, .allowsDeleting
            ]
            if localItem.isDirectory {
                caps.insert(.allowsContentEnumerating)
                caps.insert(.allowsAddingSubItems)
            }
            return caps
        }
        if isContainer(localItem) {
            // Moodle folders and stand-ins are read-only containers. Users can still
            // add their own files and folders inside them; those are stored in the
            // personal files folder, so a course refresh cannot delete them.
            return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
        }
        return [.allowsReading]
    }

    var filename: String {
        localItem.filename
    }

    var contentType: UTType {
        if localItem.isDirectory {
            return .folder
        }
        if let mimeType = localItem.contentType {
            return UTType(mimeType: mimeType) ?? inferType()
        }
        return inferType()
    }

    var documentSize: NSNumber? {
        localItem.fileSize > 0 ? NSNumber(value: localItem.fileSize) : nil
    }

    var creationDate: Date? {
        localItem.creationDate
    }

    var contentModificationDate: Date? {
        localItem.modificationDate
    }

    var itemVersion: NSFileProviderItemVersion {
        let contentVersion = localItem.contentVersion ?? "1"
        // Renaming or tagging leaves the date alone, so the name and tags go in
        // the version for the system to notice them.
        let metadataVersion = (localItem.modificationDate.map { String($0.timeIntervalSince1970) } ?? contentVersion)
            + "|" + Self.digest(Data(localItem.filename.utf8) + Data([0]) + (localItem.tagData ?? Data()))
            + DownloadRetention.metadataVersionSuffix(for: localItem)
            + "|" + FinderActionState.revision
        return NSFileProviderItemVersion(
            contentVersion: Data(contentVersion.utf8),
            metadataVersion: Data(metadataVersion.utf8)
        )
    }

    var isDownloaded: Bool {
        localItem.syncState == .materialized
    }

    var isDownloading: Bool {
        localItem.syncState == .downloading
    }

    var isUploaded: Bool {
        !isUserItem(localItem)
    }

    var isUploading: Bool {
        false
    }

    var isMostRecentVersionDownloaded: Bool {
        localItem.syncState == .materialized
    }

    var tagData: Data? {
        localItem.tagData
    }

    var contentPolicy: NSFileProviderContentPolicy {
        DownloadRetention.contentPolicy(for: localItem)
    }

    var lastUsedDate: Date? {
        openedAt
    }

    var userInfo: [AnyHashable: Any]? {
        FinderActionState.userInfo(for: localItem)
    }

    /// A short digest; versions are compared, never read.
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Type Inference

    private func inferType() -> UTType {
        let ext = (localItem.filename as NSString).pathExtension.lowercased()
        if let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }
}

/// Represents the root container of the File Provider domain.
final class RootContainerItem: NSObject, NSFileProviderItem {
    private let rootName: String

    init(filename: String) {
        self.rootName = filename
    }

    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { rootName }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] }
    var itemVersion: NSFileProviderItemVersion {
        let versionData = Data(rootName.utf8)
        let metadataVersion = Data((rootName + "|" + FinderActionState.revision).utf8)
        return NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: metadataVersion)
    }
    var userInfo: [AnyHashable: Any]? { FinderActionState.rootUserInfo() }
}
