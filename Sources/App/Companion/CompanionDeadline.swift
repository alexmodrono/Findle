// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain

/// An assignment due or a quiz closing in the course the companion shows, with
/// where the user stands on it.
struct CompanionDeadline: Identifiable, Equatable {
    enum Kind: Equatable { case assignment, quiz }

    let kind: Kind
    let id: String
    let name: String
    let due: Date
    let status: String
    /// Whether there is still something for the user to do.
    let needsAction: Bool

    var symbolName: String { kind == .assignment ? "doc.text" : "checklist" }

    var dueText: String {
        (kind == .assignment ? "Due " : "Closes ") + due.formatted(date: .abbreviated, time: .shortened)
    }

    /// The tooltip and VoiceOver label.
    var summary: String { "\(name). \(dueText). \(status)." }

    /// What isn't due yet in `course`, soonest first. Courses the user doesn't
    /// sync, and past deadlines, show nothing.
    static func upcoming(for course: MoodleCourse, assignments: [MoodleAssignment], quizzes: [MoodleQuiz],
                         attempts: [MoodleQuizAttempt], now: Date = Date()) -> [CompanionDeadline] {
        let assignmentsByID = Dictionary(assignments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let attemptsByQuiz = Dictionary(grouping: attempts, by: \.quizID)
        return CourseDataService.upcomingCoursework(courses: [course], assignments: assignments, quizzes: quizzes, now: now)
            .filter { $0.courseID == course.id }
            .map { work in
                switch work.kind {
                case .assignment:
                    let assignment = assignmentsByID[work.id]
                    let status: String
                    if assignment?.graded == true {
                        status = assignment?.grade.map { "Graded: \($0)" } ?? "Graded"
                    } else {
                        status = work.submitted == true ? "Submitted" : "Not submitted"
                    }
                    return CompanionDeadline(kind: .assignment, id: "assign:\(work.id)", name: work.name, due: work.due,
                                             status: status, needsAction: work.submitted != true && assignment?.graded != true)
                case .quiz:
                    let states = Set((attemptsByQuiz[work.id] ?? []).map(\.state))
                    let status = states.contains("finished") ? "Attempted"
                        : states.contains("inprogress") ? "In progress" : "Not attempted"
                    return CompanionDeadline(kind: .quiz, id: "quiz:\(work.id)", name: work.name, due: work.due,
                                             status: status, needsAction: !states.contains("finished"))
                }
            }
    }
}
