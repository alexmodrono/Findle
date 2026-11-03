import XCTest
@testable import SharedDomain

final class ToolbarMenuTests: XCTestCase {
    func testTheMenuListsSyncDeadlinesCoursesAndSettings() throws {
        let due = Date(timeIntervalSince1970: 2_000_000)
        let snapshot = WidgetSnapshot(
            status: .upToDate,
            deadlines: [.init(id: "1", name: "Essay", courseName: "Algebra", due: due, status: "Not submitted",
                              needsAction: true, itemID: "assign-s-1-10")],
            courses: [.init(id: 1, name: "Algebra"), .init(id: 2, name: "Physics")])
        let entries = ToolbarMenu.entries(for: snapshot)
        XCTAssertEqual(entries.first, .action("Sync Now", FindleLinks.sync))
        XCTAssertTrue(entries.contains(.header("Due This Week")))
        XCTAssertTrue(entries.contains(.action("Algebra", try XCTUnwrap(FindleLinks.openCourse(1)))))
        XCTAssertTrue(entries.contains { if case .action(let title, let url) = $0 {
            return title.hasPrefix("Essay — ") && url == FindleLinks.reveal(itemID: "assign-s-1-10") }; return false })
        XCTAssertEqual(entries.last, .action("Findle Settings…", FindleLinks.settings))
    }

    func testSignedOutOffersSignIn() {
        XCTAssertEqual(ToolbarMenu.entries(for: nil), [.action("Sign In to Findle…", FindleLinks.settings)])
        XCTAssertEqual(ToolbarMenu.entries(for: .signedOut), [.action("Sign In to Findle…", FindleLinks.settings)])
    }

    func testOpenLinksRoundTripAndOlderSnapshotsStillRead() throws {
        XCTAssertEqual(FindleLinks.openedCourse(in: try XCTUnwrap(FindleLinks.openCourse(42))), 42)
        let old = Data(#"{"status":"upToDate","deadlines":[],"recentFiles":[]}"#.utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("old-\(UUID().uuidString).json")
        try old.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(WidgetSnapshot.read(from: url)?.status, .upToDate, "A snapshot from before the toolbar button still reads")
    }
}
