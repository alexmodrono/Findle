import Foundation
import Testing
import SharedDomain

struct DueThisWeekTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func theNextSevenDaysAcrossSyncedCourses() {
        let algebra = MoodleCourse(id: 1, shortName: "ALG", fullName: "Algebra", siteID: "s")
        let history = MoodleCourse(id: 2, shortName: "HIS", fullName: "History", siteID: "s", isSyncEnabled: false)
        let entries = DueThisWeekEntry.entries(
            courses: [algebra, history],
            assignments: [MoodleAssignment(id: 1, courseID: 1, name: "Essay", dueDate: now.addingTimeInterval(2 * 86_400), moduleID: 40),
                          MoodleAssignment(id: 2, courseID: 1, name: "Later", dueDate: now.addingTimeInterval(8 * 86_400)),
                          MoodleAssignment(id: 3, courseID: 2, name: "Unsynced", dueDate: now.addingTimeInterval(86_400))],
            quizzes: [MoodleQuiz(id: 4, courseID: 1, name: "Quiz", closeDate: now.addingTimeInterval(86_400))],
            attempts: [], now: now)
        #expect(entries.map(\.name) == ["Quiz", "Essay"])
        #expect(entries.last?.line.hasPrefix("Essay (Algebra), ") == true)
        #expect(entries.last?.line.hasSuffix("Not submitted") == true)
        #expect(entries.last?.itemID == "assign-s-1-40", "Clicking an assignment reveals its folder")
        #expect(entries.first?.itemID == nil, "Quizzes have no folder")
    }
}
