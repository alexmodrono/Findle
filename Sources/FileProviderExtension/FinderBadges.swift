// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import SharedDomain

/// The badges Finder draws on items, declared as NSFileProviderDecorations in
/// the extension's Info.plist. The database works out which apply (ItemBadges).
enum FinderBadges {
    static let dueSoon = NSFileProviderItemDecorationIdentifier("\(BundleIdentifiers.prefix).badge.due-soon")
    static let new = NSFileProviderItemDecorationIdentifier("\(BundleIdentifiers.prefix).badge.new")
    static let kept = NSFileProviderItemDecorationIdentifier("\(BundleIdentifiers.prefix).badge.kept")

    static func identifier(for badge: ItemBadges) -> NSFileProviderItemDecorationIdentifier? {
        switch badge {
        case .dueSoon: dueSoon
        case .new: new
        case .kept: kept
        default: nil
        }
    }

    /// Finder draws only the first badge, so they go most pressing first.
    static func decorations(for item: LocalItem) -> [NSFileProviderItemDecorationIdentifier]? {
        let identifiers = item.badges.ordered.compactMap(identifier(for:))
        return identifiers.isEmpty ? nil : identifiers
    }

    /// Part of the metadata version, so a badge change reaches Finder.
    static func metadataVersionSuffix(for item: LocalItem) -> String {
        item.badges.isEmpty ? "" : "|b\(item.badges.rawValue)"
    }
}
