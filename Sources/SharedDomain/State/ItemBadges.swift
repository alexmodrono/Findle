// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// The state Finder badges an item with. Each badge reflects real state: what
/// the user hasn't seen, what Findle keeps downloaded, and coursework due soon.
public struct ItemBadges: OptionSet, Sendable, Codable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// An unsubmitted assignment due within `dueSoonWindow`.
    public static let dueSoon = ItemBadges(rawValue: 1 << 0)
    /// A sync brought the item in, or something inside the folder, and the user
    /// hasn't opened it or its folder since.
    public static let new = ItemBadges(rawValue: 1 << 1)
    /// Kept downloaded with Keep Downloaded.
    public static let kept = ItemBadges(rawValue: 1 << 2)
    /// The activity is complete on Moodle.
    public static let completed = ItemBadges(rawValue: 1 << 3)
    /// Not drawn: the activity uses manual completion, so Finder can offer
    /// Mark as Done or Mark as Not Done.
    public static let manualCompletion = ItemBadges(rawValue: 1 << 4)
    /// Moodle replaced a file the user had downloaded; the previous version is kept.
    public static let updated = ItemBadges(rawValue: 1 << 5)

    /// How far ahead an assignment counts as due soon.
    public static let dueSoonWindow: TimeInterval = 3 * 24 * 60 * 60

    /// Finder shows one badge per item, so the most pressing one goes first.
    public static let priority: [ItemBadges] = [.dueSoon, .new, .updated, .completed, .kept]

    /// The badges in the order Finder should consider them.
    public var ordered: [ItemBadges] {
        Self.priority.filter { contains($0) }
    }
}
