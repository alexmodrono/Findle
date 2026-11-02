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

    var line: String {
        "\(name) (\(courseName)), \(due.formatted(.dateTime.weekday(.wide).hour().minute())). \(status)"
    }

    static func entries(courses: [MoodleCourse], assignments: [MoodleAssignment], quizzes: [MoodleQuiz],
                        attempts: [MoodleQuizAttempt], now: Date) -> [DueThisWeekEntry] {
        let end = now.addingTimeInterval(7 * 24 * 60 * 60)
        return courses.filter(\.isSyncEnabled).flatMap { course in
            CompanionDeadline.upcoming(for: course, assignments: assignments, quizzes: quizzes, attempts: attempts, now: now)
                .filter { $0.due <= end }
                .map { DueThisWeekEntry(name: $0.name, courseName: course.fullName, due: $0.due, status: $0.status) }
        }
        .sorted { ($0.due, $0.name) < ($1.due, $1.name) }
    }
}
