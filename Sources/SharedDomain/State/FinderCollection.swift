// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// Read-only folders at the Findle root that gather items from every course.
/// Their entries are symbolic links to the real items, so nothing is stored
/// twice; the database keeps them up to date.
public enum FinderCollection: String, CaseIterable, Sendable {
    case recentlyAdded = "recent"
    case dueThisWeek = "due"
    case keptOffline = "kept"

    public var name: String {
        switch self {
        case .recentlyAdded: "Recently Added"
        case .dueThisWeek: "Due This Week"
        case .keptOffline: "Kept Offline"
        }
    }

    /// How far ahead Due This Week looks.
    public static let dueWindow: TimeInterval = 7 * 24 * 60 * 60

    static let prefix = "collection-"

    public func folderID(siteID: String) -> String {
        "\(Self.prefix)\(siteID)-\(rawValue)"
    }

    public func entryID(siteID: String, itemID: String) -> String {
        "\(folderID(siteID: siteID))/\(itemID)"
    }

    /// Whether `id` is a collection folder or one of its entries.
    public static func contains(_ id: String) -> Bool {
        id.hasPrefix(prefix)
    }
}

extension LocalItem {
    /// A collection folder or entry, rather than a course item or personal file.
    public var isInFinderCollection: Bool { FinderCollection.contains(id) }
}
