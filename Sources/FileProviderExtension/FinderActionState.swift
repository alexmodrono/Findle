// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SharedDomain

/// The state each item publishes to Finder through `userInfo`, so the activation
/// rule of every Findle action in the extension's Info.plist can hide the action
/// where it would do nothing.
///
/// The rules read these keys as `$fileproviderItem.userInfo.<key>`. Renaming a key
/// or a kind means changing the rules too; `FinderActionRuleTests` evaluates them.
enum FinderActionState {
    static let kindKey = "kind"
    static let moodleKey = "moodle"
    static let keptKey = "kept"

    enum Kind: String {
        case root, course, section, folder, file
    }

    static func userInfo(for item: LocalItem) -> [AnyHashable: Any] {
        let isMoodleItem = !item.isLocal
        return [
            kindKey: kind(of: item).rawValue,
            moodleKey: isMoodleItem,
            // Keeping a folder also marks the personal files inside it, but only
            // Moodle files can be downloaded again, so only they count as kept.
            keptKey: isMoodleItem && item.isPinned
        ]
    }

    static func rootUserInfo() -> [AnyHashable: Any] {
        [kindKey: Kind.root.rawValue, moodleKey: false, keptKey: false]
    }

    /// Course and section folders open the course page in Moodle, so Open Course
    /// Page only adds something for module folders and files.
    static func kind(of item: LocalItem) -> Kind {
        guard item.isDirectory else { return .file }
        if item.id.hasPrefix("course-") { return .course }
        if item.id.hasPrefix("section-") { return .section }
        return .folder
    }

    /// Part of the metadata version, so the system re-reads `userInfo` from items
    /// it saw before they published any. Bump it when the published state changes.
    static let revision = "a1"
}
