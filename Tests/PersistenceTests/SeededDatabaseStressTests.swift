import XCTest
import SharedDomain
@testable import FindlePersistence

final class SeededDatabaseStressTests: XCTestCase {
    func testSeededCoursePublicationFailureAndReopenSequence() throws {
        let seedText = ProcessInfo.processInfo.environment["FINDLE_STRESS_SEED"] ?? "20261029"
        let seed = try XCTUnwrap(UInt64(seedText), "FINDLE_STRESS_SEED must be an unsigned integer")
        var random = Generator(state: seed)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("stress.sqlite").path
        let database = try Database(path: path)
        var model: [Int: [LocalItem]] = [:]
        var cursors: [Int: SyncCursor] = [:]
        print("Seeded database stress: seed=\(seed), rounds=80")

        for round in 0..<80 {
            let course = Int(random.next() % 4) + 1
            let count = Int(random.next() % 12)
            let nextItems = (0..<count).map { index in
                LocalItem(id: "c\(course)-item\(index)", parentID: nil, siteID: "stress-site", courseID: course,
                          remoteID: index, filename: "fixture-\(index).pdf", isDirectory: false,
                          fileSize: Int64(round + index), syncState: .placeholder)
            }
            let nextIDs = Set(nextItems.map(\.id))
            let deleted = (model[course] ?? []).map(\.id).filter { !nextIDs.contains($0) }
            let cursor = SyncCursor(courseID: course, siteID: "stress-site",
                                    lastSyncDate: Date(timeIntervalSince1970: Double(round + 1)), itemCount: count)
            let outline = CourseOutlineSnapshot(courseID: course, capturedAt: cursor.lastSyncDate, sections: [])
            let context = "seed=\(seed), round=\(round), course=\(course)"
            if random.next() % 3 == 0 {
                try database.execute("CREATE TRIGGER reject_stress_cursor BEFORE INSERT ON sync_cursors BEGIN SELECT RAISE(ABORT, 'stress rollback'); END")
                XCTAssertThrowsError(try database.commitCourseSync(items: nextItems, deletingItemIDs: deleted,
                                                                  cursor: cursor, outline: outline), context)
                XCTAssertEqual(try database.fetchSyncCursor(courseID: course, siteID: "stress-site"), cursors[course], context)
                let unchanged = try database.fetchItems(courseID: course, siteID: "stress-site")
                XCTAssertEqual(unchanged.sorted { $0.id < $1.id }, (model[course] ?? []).sorted { $0.id < $1.id }, context)
                try database.execute("DROP TRIGGER reject_stress_cursor")
            }
            try database.commitCourseSync(items: nextItems, deletingItemIDs: deleted, cursor: cursor, outline: outline)
            model[course] = nextItems
            cursors[course] = cursor
            // A separate connection verifies durable visibility after every replay.
            let reader = try Database(path: path)
            for (id, expected) in model {
                let actual = try reader.fetchItems(courseID: id, siteID: "stress-site")
                XCTAssertEqual(actual.sorted { $0.id < $1.id }, expected.sorted { $0.id < $1.id }, context)
                XCTAssertEqual(try reader.fetchSyncCursor(courseID: id, siteID: "stress-site"), cursors[id], context)
            }
        }
    }

    private struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }
}
