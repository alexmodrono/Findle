// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain

/// An assignment or quiz due in the next seven days, as Shortcuts reads it out.
struct DueThisWeekEntry: Equatable {
    let name: String
    let courseName: String
    let due: Date
    let status: String
    var needsAction = true
    /// The assignment's folder in Finder, when it has one.
    var itemID: String?

    var line: String {
        "\(name) (\(courseName)), \(due.formatted(.dateTime.weekday(.wide).hour().minute())). \(status)"
    }

    static func entries(courses: [MoodleCourse], assignments: [MoodleAssignment], quizzes: [MoodleQuiz],
                        attempts: [MoodleQuizAttempt], now: Date) -> [DueThisWeekEntry] {
        let end = now.addingTimeInterval(7 * 24 * 60 * 60)
        let modules = Dictionary(assignments.map { ($0.id, $0.moduleID) }, uniquingKeysWith: { first, _ in first })
        return courses.filter(\.isSyncEnabled).flatMap { course in
            CompanionDeadline.upcoming(for: course, assignments: assignments, quizzes: quizzes, attempts: attempts, now: now)
                .filter { $0.due <= end }
                .map { deadline in
                    let assignmentID = deadline.kind == .assignment ? Int(deadline.id.dropFirst("assign:".count)) : nil
                    let folder = assignmentID.flatMap { modules[$0] ?? nil }
                        .map { "assign-\(course.siteID)-\(course.id)-\($0)" }
                    return DueThisWeekEntry(name: deadline.name, courseName: course.fullName, due: deadline.due,
                                            status: deadline.status, needsAction: deadline.needsAction, itemID: folder)
                }
        }
        .sorted { ($0.due, $0.name) < ($1.due, $1.name) }
    }
}
