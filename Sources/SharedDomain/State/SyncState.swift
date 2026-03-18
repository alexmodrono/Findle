// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// Per-item synchronization state.
public enum ItemSyncState: String, Sendable, Codable, Equatable {
    case placeholder
    case downloading
    case materialized
    case evicting
    case stale
    case error
}

/// Per-course subscription and sync state.
public enum CourseSubscriptionState: String, Sendable, Codable, Equatable {
    case discovered
    case subscribed
    case syncing
    case synced
    case stale
    case unsubscribed
    case error
}

/// A sync cursor representing the last-known state for incremental sync.
public struct SyncCursor: Sendable, Codable, Equatable {
    public let courseID: Int
    public let siteID: String
    public var lastSyncDate: Date
    public var lastModified: Date?
    public var itemCount: Int

    public init(
        courseID: Int,
        siteID: String,
        lastSyncDate: Date = Date(),
        lastModified: Date? = nil,
        itemCount: Int = 0
    ) {
        self.courseID = courseID
        self.siteID = siteID
        self.lastSyncDate = lastSyncDate
        self.lastModified = lastModified
        self.itemCount = itemCount
    }
}

/// Represents a locally tracked item for the File Provider.
public struct LocalItem: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let parentID: String?
    public let siteID: String
    public let courseID: Int
    public let remoteID: Int
    public let filename: String
    public let isDirectory: Bool
    public var contentType: String?
    public var fileSize: Int64
    public var creationDate: Date?
    public var modificationDate: Date?
    public var syncState: ItemSyncState
    public var isPinned: Bool
    public var localPath: String?
    public var remoteURL: URL?
    public var contentVersion: String?
    public var tagData: Data?
    /// When `true`, the item was created locally by the user and should never be
    /// synced to Moodle.  The sync engine skips local items entirely.
    public var isLocal: Bool

    public init(
        id: String = UUID().uuidString,
        parentID: String? = nil,
        siteID: String,
        courseID: Int,
        remoteID: Int,
        filename: String,
        isDirectory: Bool = false,
        contentType: String? = nil,
        fileSize: Int64 = 0,
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        syncState: ItemSyncState = .placeholder,
        isPinned: Bool = false,
        localPath: String? = nil,
        remoteURL: URL? = nil,
        contentVersion: String? = nil,
        tagData: Data? = nil,
        isLocal: Bool = false
    ) {
        self.id = id
        self.parentID = parentID
        self.siteID = siteID
        self.courseID = courseID
        self.remoteID = remoteID
        self.filename = filename
        self.isDirectory = isDirectory
        self.contentType = contentType
        self.fileSize = fileSize
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.syncState = syncState
        self.isPinned = isPinned
        self.localPath = localPath
        self.remoteURL = remoteURL
        self.contentVersion = contentVersion
        self.tagData = tagData
        self.isLocal = isLocal
    }
}
