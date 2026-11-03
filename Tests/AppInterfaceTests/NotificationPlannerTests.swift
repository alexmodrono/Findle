import Foundation
import Testing
import SharedDomain

/// Notifications carry news, and setting up or an unchanged sync says nothing.
struct NotificationPlannerTests {
    private let algebra = MoodleCourse(id: 1, shortName: "ALG", fullName: "Algebra", siteID: "s")
    private let physics = MoodleCourse(id: 2, shortName: "PHY", fullName: "Physics", siteID: "s")
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func file(_ name: String, course: Int) -> LocalItem {
        LocalItem(id: "file-\(name)", parentID: "w", siteID: "s", courseID: course, remoteID: 1, filename: name)
    }

    @Test func newFilesAreGroupedByCourse() {
        let notices = NotificationPlanner.newFiles(
            arrived: [file("b.pdf", course: 1), file("a.pdf", course: 1), file("c.pdf", course: 1), file("lab.pdf", course: 2),
                      LocalItem(id: "w2", siteID: "s", courseID: 2, remoteID: 1, filename: "Week 2", isDirectory: true)],
            courses: [algebra, physics])
        #expect(notices.map(\.title) == ["3 new files in Algebra", "New in Physics"])
        #expect(notices.map(\.body) == ["a.pdf, b.pdf and 1 more", "lab.pdf"])
        #expect(notices.first?.itemID == "file-a.pdf", "Clicking reveals the first file")
        #expect(NotificationPlanner.newFiles(arrived: [], courses: [algebra]).isEmpty, "A sync without changes says nothing")
    }

    @Test func anAssignmentDueWithinADayIsAnnouncedOnce() {
        let assignments = [
            MoodleAssignment(id: 1, courseID: 1, name: "Essay", dueDate: now.addingTimeInterval(3_600), moduleID: 10),
            MoodleAssignment(id: 2, courseID: 1, name: "Done", dueDate: now.addingTimeInterval(3_600), submitted: true),
            MoodleAssignment(id: 3, courseID: 1, name: "Later", dueDate: now.addingTimeInterval(3 * 86_400)),
            MoodleAssignment(id: 4, courseID: 1, name: "Past", dueDate: now.addingTimeInterval(-60)),
        ]
        let first = NotificationPlanner.dueSoon(assignments: assignments, courses: [algebra], siteID: "s", now: now, announced: [])
        #expect(first.notices.map(\.title) == ["Essay is due soon"])
        #expect(first.notices.first?.itemID == "assign-s-1-10")
        let again = NotificationPlanner.dueSoon(assignments: assignments, courses: [algebra], siteID: "s", now: now, announced: first.keys)
        #expect(again.notices.isEmpty)

        var moved = assignments
        moved[0] = MoodleAssignment(id: 1, courseID: 1, name: "Essay", dueDate: now.addingTimeInterval(7_200), moduleID: 10)
        #expect(NotificationPlanner.dueSoon(assignments: moved, courses: [algebra], siteID: "s", now: now, announced: first.keys)
            .notices.count == 1, "A new due date is news again")
    }

    @Test func gradesAreAnnouncedWhenTheyArrive() {
        let before = [MoodleAssignment(id: 1, courseID: 1, name: "Essay", submitted: true),
                      MoodleAssignment(id: 2, courseID: 1, name: "Lab", submitted: true, graded: true, grade: "7")]
        let after = [MoodleAssignment(id: 1, courseID: 1, name: "Essay", moduleID: 10, submitted: true, graded: true, grade: "9"),
                     MoodleAssignment(id: 2, courseID: 1, name: "Lab", submitted: true, graded: true, grade: "7")]
        let notices = NotificationPlanner.gradesPosted(before: before, after: after, courses: [algebra], siteID: "s")
        #expect(notices.map(\.title) == ["Grade posted: Essay"])
        #expect(notices.first?.body == "Algebra · 9")
        #expect(NotificationPlanner.gradesPosted(before: [], after: after, courses: [algebra], siteID: "s").isEmpty,
                "The first refresh after setup is a baseline")
    }
}
