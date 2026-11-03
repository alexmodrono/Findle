import XCTest
@testable import SharedDomain

final class CourseworkSummaryTests: XCTestCase {
    private let due = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnAssignmentSummarySaysWhereTheStudentStands() throws {
        let graded = CourseworkSummary.assignment(
            name: "Essay", courseName: "Algebra",
            assignment: MoodleAssignment(id: 1, courseID: 1, name: "Essay <draft>", dueDate: due, moduleID: 9, submitted: true,
                                         graded: true, grade: "9"),
            brief: "Write 500 words.", moodleURL: URL(string: "https://moodle.example.edu/mod/assign/view.php?id=9"))
        XCTAssertEqual(graded.status, "Graded")
        XCTAssertEqual(graded.headline, "Grade 9", "The thumbnail shows the score once graded")
        XCTAssertTrue(graded.html.contains("Essay &lt;draft&gt;"), "Text is escaped")
        XCTAssertEqual(CourseworkSummary.decode(graded.encoded()), graded)
        XCTAssertEqual(graded.encoded(), graded.encoded(), "Stable bytes, so unchanged summaries aren't rewritten")

        let open = CourseworkSummary.assignment(name: "Lab", courseName: "Physics",
                                                assignment: MoodleAssignment(id: 2, courseID: 2, name: "Lab", dueDate: due),
                                                brief: nil, moodleURL: nil)
        XCTAssertEqual(open.status, "Not submitted")
        XCTAssertTrue(open.headline.hasPrefix("Due "))
    }

    func testAQuizSummaryShowsTheBestScore() {
        let quiz = MoodleQuiz(id: 4, courseID: 1, name: "Quiz 1", closeDate: due, moduleID: 12)
        let attempts = [MoodleQuizAttempt(id: 1, quizID: 4, attemptNumber: 1, state: "finished", sumGrades: 6.5),
                        MoodleQuizAttempt(id: 2, quizID: 4, attemptNumber: 2, state: "finished", sumGrades: 8)]
        let summary = CourseworkSummary.quiz(name: "Quiz 1", courseName: "Algebra", quiz: quiz, attempts: attempts, moodleURL: nil)
        XCTAssertEqual(summary.status, "Attempted")
        XCTAssertEqual(summary.headline, "Score 8")
        XCTAssertTrue(CourseworkSummary.isSummary(CourseworkSummary.summaryID(for: .quiz, siteID: "s", courseID: 1, moduleID: 12)))
    }
}
