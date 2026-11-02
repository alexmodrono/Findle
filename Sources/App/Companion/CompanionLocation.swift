// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SharedDomain

/// Where the folder Finder shows is in Findle, from its File Provider identity
/// rather than its name, so a renamed folder still finds its course.
struct CompanionLocation: Equatable {
    let course: MoodleCourse
    /// The folder and the folders holding it, innermost first.
    let folderIDs: [String]

    /// `item` looks an item up by identifier. Returns nil for an item Findle
    /// doesn't know or whose course isn't one of `courses`.
    static func resolve(itemID: String, siteID: String, courses: [MoodleCourse],
                        item: (String) -> LocalItem?) -> CompanionLocation? {
        var folderIDs: [String] = []
        var course: MoodleCourse?
        var next: String? = itemID
        // Parent chains are short; the bound only guards against a cycle.
        while let id = next, folderIDs.count < 64, !folderIDs.contains(id),
              let found = item(id), found.siteID == siteID {
            folderIDs.append(id)
            course = course ?? courses.first { $0.id == found.courseID && $0.siteID == siteID }
            next = found.parentID
        }
        guard let course, !folderIDs.isEmpty else { return nil }
        return CompanionLocation(course: course, folderIDs: folderIDs)
    }
}
