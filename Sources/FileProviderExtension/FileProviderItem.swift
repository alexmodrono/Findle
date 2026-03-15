// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import UniformTypeIdentifiers
import SharedDomain

/// Adapts a LocalItem to NSFileProviderItem for the File Provider framework.
final class FileProviderItem: NSObject, NSFileProviderItem {
    private let localItem: LocalItem

    init(localItem: LocalItem) {
        self.localItem = localItem
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
        if localItem.isDirectory {
            return [.allowsReading, .allowsContentEnumerating]
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
        let versionData = Data(contentVersion.utf8)
        return NSFileProviderItemVersion(
            contentVersion: versionData,
            metadataVersion: versionData
        )
    }

    var isDownloaded: Bool {
        localItem.syncState == .materialized
    }

    var isDownloading: Bool {
        localItem.syncState == .downloading
    }

    var isUploaded: Bool {
        true // read-only content is always "uploaded"
    }

    var isUploading: Bool {
        false
    }

    var tagData: Data? {
        localItem.tagData
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
    var capabilities: NSFileProviderItemCapabilities { [.allowsReading, .allowsContentEnumerating] }
    var itemVersion: NSFileProviderItemVersion {
        let versionData = Data(rootName.utf8)
        return NSFileProviderItemVersion(contentVersion: versionData, metadataVersion: versionData)
    }
}
