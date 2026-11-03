import CoreSpotlight
import Foundation
import Testing
import SharedDomain

/// Spotlight finds files, assignments and quizzes with their course and section.
struct SpotlightIndexerTests {
    private let course = MoodleCourse(id: 7, shortName: "ALG", fullName: "Algebra", siteID: "site")
    private let due = Date(timeIntervalSince1970: 2_000_000)
    private var items: [LocalItem] {
        [
            LocalItem(id: "course-site-7", siteID: "site", courseID: 7, remoteID: 7, filename: "Algebra", isDirectory: true),
            LocalItem(id: "section-site-7-1", parentID: "course-site-7", siteID: "site", courseID: 7, remoteID: 1,
                      filename: "Week 3", isDirectory: true),
            LocalItem(id: "file-lab", parentID: "section-site-7-1", siteID: "site", courseID: 7, remoteID: 2,
                      filename: "Lab 3.pdf", contentType: "application/pdf", author: "Dr. Ruiz"),
            LocalItem(id: "assign-site-7-40", parentID: "section-site-7-1", siteID: "site", courseID: 7, remoteID: 40,
                      filename: "Lab 3 report", isDirectory: true),
        ]
    }

    private func entries() -> [String: CSSearchableItem] {
        let found = SpotlightIndexer.searchableItems(
            courses: [course], items: items,
            assignments: [MoodleAssignment(id: 5, courseID: 7, name: "Lab 3 report", dueDate: due, moduleID: 40)],
            quizzes: [MoodleQuiz(id: 9, courseID: 7, name: "Lab 3 quiz", closeDate: due)], siteName: "Campus")
        return Dictionary(uniqueKeysWithValues: found.map { ($0.uniqueIdentifier, $0) })
    }

    @Test func filesAssignmentsAndQuizzesAreFoundWithTheirSection() throws {
        let entries = entries()
        let prefix = BundleIdentifiers.spotlightPrefix
        let file = try #require(entries["\(prefix).item.file-lab"])
        #expect(file.attributeSet.title == "Lab 3.pdf")
        #expect(file.attributeSet.contentDescription == "Week 3 › Algebra — Campus")
        #expect(file.attributeSet.authorNames == ["Dr. Ruiz"])

        let assignment = try #require(entries["\(prefix).item.assign-site-7-40"])
        #expect(assignment.attributeSet.dueDate == due)
        #expect(assignment.attributeSet.contentDescription?.hasPrefix("Assignment · Due ") == true)

        let quiz = try #require(entries["\(prefix).quiz.site.9"])
        #expect(quiz.attributeSet.title == "Lab 3 quiz")
        #expect(Set(entries.values.map(\.domainIdentifier)).count == 1, "Every entry belongs to its course, so the course can be replaced")
        #expect(entries.count == 4, "Folders other than assignments aren't results of their own")
    }

    @Test func resultsNameWhatToOpen() {
        let prefix = BundleIdentifiers.spotlightPrefix
        #expect(SpotlightIndexer.result(for: "\(prefix).course.site.7") == .course(7))
        #expect(SpotlightIndexer.result(for: "\(prefix).item.file-site-1-2") == .item("file-site-1-2"))
        #expect(SpotlightIndexer.result(for: "\(prefix).quiz.site.9") == .quiz(9))
        #expect(SpotlightIndexer.result(for: "other.item.x") == nil)
    }
}
