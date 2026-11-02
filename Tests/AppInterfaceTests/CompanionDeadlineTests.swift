import Foundation
import Testing
import SharedDomain

struct CompanionDeadlineTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let course = MoodleCourse(id: 1, shortName: "ALG", fullName: "Algebra", siteID: "site", isSyncEnabled: true)

    @Test func upcomingCourseworkShowsWhereTheUserStands() {
        let assignments = [
            MoodleAssignment(id: 1, courseID: 1, name: "Essay", dueDate: now.addingTimeInterval(7_200)),
            MoodleAssignment(id: 2, courseID: 1, name: "Lab", dueDate: now.addingTimeInterval(3_600), submitted: true),
            MoodleAssignment(id: 3, courseID: 1, name: "Draft", dueDate: now.addingTimeInterval(9_000), submitted: true,
                             graded: true, grade: "8.5"),
            MoodleAssignment(id: 4, courseID: 1, name: "Past", dueDate: now.addingTimeInterval(-60)),
            MoodleAssignment(id: 5, courseID: 2, name: "Other course", dueDate: now.addingTimeInterval(60)),
            MoodleAssignment(id: 6, courseID: 1, name: "Undated"),
        ]
        let quizzes = [MoodleQuiz(id: 9, courseID: 1, name: "Quiz 1", closeDate: now.addingTimeInterval(5_000)),
                       MoodleQuiz(id: 10, courseID: 1, name: "Quiz 2", closeDate: now.addingTimeInterval(10_000))]
        let attempts = [MoodleQuizAttempt(id: 1, quizID: 9, attemptNumber: 1, state: "finished")]

        let deadlines = CompanionDeadline.upcoming(for: course, assignments: assignments, quizzes: quizzes,
                                                   attempts: attempts, now: now)
        #expect(deadlines.map(\.name) == ["Lab", "Quiz 1", "Essay", "Draft", "Quiz 2"], "Soonest first; past items drop off")
        #expect(deadlines.map(\.status) == ["Submitted", "Attempted", "Not submitted", "Graded: 8.5", "Not attempted"])
        #expect(deadlines.map(\.needsAction) == [false, false, true, false, true])
    }

    @Test func coursesWithoutCourseworkOrNotSyncedShowNothing() {
        #expect(CompanionDeadline.upcoming(for: course, assignments: [], quizzes: [], attempts: [], now: now).isEmpty)
        var unsynced = course
        unsynced.isSyncEnabled = false
        let assignment = MoodleAssignment(id: 1, courseID: 1, name: "Essay", dueDate: now.addingTimeInterval(60))
        #expect(CompanionDeadline.upcoming(for: unsynced, assignments: [assignment], quizzes: [], attempts: [], now: now).isEmpty)
    }
}
