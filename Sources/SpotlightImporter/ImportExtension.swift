// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import CoreSpotlight
import SharedDomain
import UniformTypeIdentifiers

/// Makes assignment and quiz summaries searchable by what they say: name,
/// course, status, grade and the assignment's brief.
final class ImportExtension: CSImportExtension {
    override func update(_ attributes: CSSearchableItemAttributeSet, forFileAt contentURL: URL) throws {
        guard let summary = CourseworkSummary.decode(try Data(contentsOf: contentURL)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        attributes.title = summary.name
        attributes.displayName = summary.name
        attributes.contentDescription = [summary.courseName, summary.status, summary.grade.map { "Grade \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
        attributes.textContent = [summary.name, summary.courseName, summary.brief].compactMap { $0 }.joined(separator: "\n")
        attributes.keywords = [summary.courseName, summary.kind == .assignment ? "assignment" : "quiz", "Moodle"]
        if let due = summary.due { attributes.dueDate = due }
        if let url = summary.moodleURL { attributes.url = url }
    }
}
