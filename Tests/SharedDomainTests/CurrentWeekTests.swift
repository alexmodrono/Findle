import XCTest
@testable import SharedDomain

final class CurrentWeekTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let day: TimeInterval = 86_400

    private func course(format: String? = "weeks", end: Date? = nil, synced: Bool = true) -> MoodleCourse {
        MoodleCourse(id: 3, shortName: "ALG", fullName: "Algebra", startDate: start, endDate: end, siteID: "s",
                     isSyncEnabled: synced, format: format)
    }

    func testTheWeekFollowsTheCourseStart() {
        XCTAssertEqual(course().weekSectionNumber(on: start), 1)
        XCTAssertEqual(course().weekSectionNumber(on: start.addingTimeInterval(6.9 * day)), 1)
        XCTAssertEqual(course().weekSectionNumber(on: start.addingTimeInterval(7 * day)), 2)
        XCTAssertNil(course().weekSectionNumber(on: start.addingTimeInterval(-1)), "Before the course starts")
        XCTAssertNil(course(end: start.addingTimeInterval(10 * day)).weekSectionNumber(on: start.addingTimeInterval(11 * day)))
        XCTAssertNil(course(format: "topics").weekSectionNumber(on: start), "Only weekly courses have weeks")
    }

    func testTheCurrentSectionAndEverythingInItIsKept() {
        let outline = CourseOutlineSnapshot(courseID: 3, capturedAt: start, sections: [
            CourseOutlineSection(id: 70, name: "General", sectionNumber: 0, visible: true, modules: []),
            CourseOutlineSection(id: 71, name: "Week 1", sectionNumber: 1, visible: true, modules: []),
            CourseOutlineSection(id: 72, name: "Week 2", sectionNumber: 2, visible: true, modules: []),
        ])
        let items = [
            LocalItem(id: "section-s-3-71", parentID: "course-s-3", siteID: "s", courseID: 3, remoteID: 71, filename: "Week 1", isDirectory: true),
            LocalItem(id: "folder-1", parentID: "section-s-3-71", siteID: "s", courseID: 3, remoteID: 9, filename: "Slides", isDirectory: true),
            LocalItem(id: "file-1", parentID: "folder-1", siteID: "s", courseID: 3, remoteID: 9, filename: "a.pdf"),
            LocalItem(id: "local-notes", parentID: "section-s-3-71", siteID: "s", courseID: 3, remoteID: 0, filename: "n.txt", isLocal: true),
            LocalItem(id: "section-s-3-72", parentID: "course-s-3", siteID: "s", courseID: 3, remoteID: 72, filename: "Week 2", isDirectory: true),
            LocalItem(id: "file-2", parentID: "section-s-3-72", siteID: "s", courseID: 3, remoteID: 10, filename: "b.pdf"),
        ]
        XCTAssertEqual(CurrentWeek.itemIDs(course: course(), outline: outline, items: items, now: start.addingTimeInterval(day)),
                       ["section-s-3-71", "folder-1", "file-1"], "Personal files are the user's own")
        XCTAssertEqual(CurrentWeek.itemIDs(course: course(), outline: outline, items: items, now: start.addingTimeInterval(8 * day)),
                       ["section-s-3-72", "file-2"])
        XCTAssertEqual(CurrentWeek.itemIDs(course: course(synced: false), outline: outline, items: items, now: start), [])
    }
}
