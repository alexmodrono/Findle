import Foundation
import Testing
import SharedDomain

struct SharedSubmissionTests {
    @Test func onlyOpenAssignmentsThatTakeFilesAreOffered() {
        func assignment(_ id: Int, files: Bool, edit: Bool, course: Int = 1) -> MoodleAssignment {
            var a = MoodleAssignment(id: id, courseID: course, name: "A\(id)", dueDate: Date(timeIntervalSince1970: Double(1_000 - id)),
                                     moduleID: 100 + id)
            a.takesFiles = files
            a.canEdit = edit
            return a
        }
        let courses = [MoodleCourse(id: 1, shortName: "ALG", fullName: "Algebra", siteID: "s"),
                       MoodleCourse(id: 2, shortName: "OFF", fullName: "Unsynced", siteID: "s", isSyncEnabled: false)]
        let list = SubmittableAssignment.list(
            assignments: [assignment(1, files: true, edit: true), assignment(2, files: true, edit: false),
                          assignment(3, files: false, edit: true), assignment(4, files: true, edit: true, course: 2),
                          assignment(5, files: true, edit: true)],
            courses: courses, siteID: "s", existingItemIDs: ["submit-s-1-101", "submit-s-2-104", "submit-s-1-105"])
        #expect(list.map(\.name) == ["A5", "A1"], "Soonest first; closed, file-less, unsynced and unsynced-folder ones left out")
        #expect(list.first?.submitFolderID == "submit-s-1-105")
    }
}
