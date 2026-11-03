// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain

/// An open assignment files can be shared to (FX-07): one that takes files
/// and that the user can still change, with its Submit folder in Finder.
struct SubmittableAssignment: Identifiable, Hashable {
    let id: Int
    let name: String
    let courseName: String
    let submitFolderID: String
    let canSubmit: Bool
    let requiresStatement: Bool
    let due: Date?

    static func list(assignments: [MoodleAssignment], courses: [MoodleCourse], siteID: String,
                     existingItemIDs: Set<String>) -> [SubmittableAssignment] {
        let names = Dictionary(courses.filter(\.isSyncEnabled).map { ($0.id, $0.fullName) }, uniquingKeysWith: { first, _ in first })
        return assignments.compactMap { assignment in
            guard assignment.acceptsFilesFromFinder, let moduleID = assignment.moduleID,
                  let courseName = names[assignment.courseID] else { return nil }
            let folder = "submit-\(siteID)-\(assignment.courseID)-\(moduleID)"
            guard existingItemIDs.contains(folder) else { return nil }
            return SubmittableAssignment(id: assignment.id, name: assignment.name, courseName: courseName, submitFolderID: folder,
                                         canSubmit: assignment.canSubmit, requiresStatement: assignment.requiresStatement,
                                         due: assignment.dueDate)
        }
        .sorted { ($0.due ?? .distantFuture, $0.name) < ($1.due ?? .distantFuture, $1.name) }
    }
}
