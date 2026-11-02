import XCTest
@testable import SharedDomain

final class WidgetSnapshotTests: XCTestCase {
    func testTheSnapshotRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("widget-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = WidgetSnapshot(
            status: .needsAttention, lastSync: Date(timeIntervalSince1970: 100),
            deadlines: [.init(id: "1", name: "Essay", courseName: "Algebra", due: Date(timeIntervalSince1970: 500),
                              status: "Not submitted", needsAction: true, itemID: "assign-s-1-10")],
            recentFiles: [.init(itemID: "file-a", name: "a.pdf", courseName: "Algebra")])
        try snapshot.write(to: url)
        XCTAssertEqual(WidgetSnapshot.read(from: url), snapshot)
        XCTAssertNil(WidgetSnapshot.read(from: url.appendingPathExtension("missing")))
    }

    func testRevealLinksRoundTrip() throws {
        let url = try XCTUnwrap(FindleLinks.reveal(itemID: "file-s-1-2-a b.pdf"))
        XCTAssertEqual(FindleLinks.revealedItem(in: url), "file-s-1-2-a b.pdf")
        XCTAssertNil(FindleLinks.revealedItem(in: FindleLinks.sync))
    }
}
