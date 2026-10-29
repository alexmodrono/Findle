import XCTest
import FileProvider
import SharedDomain
import FindlePersistence

final class SyncedItemModificationTests: XCTestCase {
    private func fixture() throws -> ProviderFixture {
        let fixture = try ProviderFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        return fixture
    }

    func testRepeatedModificationTimeUploadsReturnUnsupportedFieldWithoutWrites() throws {
        let f = try fixture()
        for identifier in ["file-a", "root-a"] {
            var item = try XCTUnwrap(f.database.fetchItem(id: identifier))
            item.modificationDate = Date(timeIntervalSince1970: 123)
            try f.database.saveItems([item])
            let anchor = try f.database.currentChangeCounter()
            for _ in 0..<13 {
                let result = try SyncedItemModification.apply(
                    to: item, changedFields: .contentModificationDate,
                    tagData: nil, hasNewContents: false, siteID: "a", database: f.database)
                XCTAssertEqual(result.item.itemIdentifier.rawValue, item.id)
                XCTAssertEqual(result.item.contentModificationDate, item.modificationDate)
                XCTAssertEqual(result.item.filename, item.filename)
                XCTAssertEqual(result.stillPendingFields, .contentModificationDate)
            }
            XCTAssertEqual(try f.database.fetchItem(id: identifier), item)
            XCTAssertEqual(try f.database.currentChangeCounter(), anchor)
        }
    }

    func testTagAndModificationTimeUploadSavesTagsThenSettlesTimestampRetryWithoutWriting() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        let tags = FinderTag.tagData(from: [.init(name: "Review", color: .blue)])
        let result = try SyncedItemModification.apply(
            to: item, changedFields: [.tagData, .contentModificationDate],
            tagData: tags, hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertEqual(result.item.tagData, tags)
        XCTAssertEqual(result.stillPendingFields, .contentModificationDate)
        let saved = try XCTUnwrap(f.database.fetchItem(id: item.id))
        XCTAssertEqual(saved.tagData, tags)
        XCTAssertEqual(saved.contentVersion, item.contentVersion)
        XCTAssertEqual(saved.remoteURL, item.remoteURL)
        let anchor = try f.database.currentChangeCounter()

        let retry = try SyncedItemModification.apply(
            to: saved, changedFields: result.stillPendingFields,
            tagData: tags, hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertEqual(retry.stillPendingFields, .contentModificationDate)
        XCTAssertEqual(try f.database.currentChangeCounter(), anchor)
        XCTAssertEqual(try f.database.fetchItem(id: item.id), saved)
    }

    func testCourseTagsRemainScopedAndCanBeClearedWithTimestampChange() throws {
        let f = try fixture()
        for site in ["a", "b"] {
            try f.database.saveCourses([.init(id: 1, shortName: "Course", fullName: "Course", siteID: site)])
        }
        let item = LocalItem(id: "course-a-1", siteID: "a", courseID: 1, remoteID: 1,
                             filename: "Course", isDirectory: true)
        try f.database.saveItems([item])
        let otherTags = [FinderTag(name: "Keep", color: .green)]
        try f.database.saveCourseTags(otherTags, courseID: 1, siteID: "b")
        let tags = [FinderTag(name: "Review", color: .blue)]
        let result = try SyncedItemModification.apply(
            to: item, changedFields: [.tagData, .contentModificationDate],
            tagData: FinderTag.tagData(from: tags), hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertEqual(try f.database.fetchCourseTags(courseID: 1, siteID: "a"), tags)
        XCTAssertEqual(result.item.tagData, FinderTag.tagData(from: tags))
        XCTAssertEqual(result.stillPendingFields, .contentModificationDate)

        let cleared = try SyncedItemModification.apply(
            to: item, changedFields: [.tagData, .contentModificationDate],
            tagData: nil, hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertNil(cleared.item.tagData)
        XCTAssertTrue(try f.database.fetchCourseTags(courseID: 1, siteID: "a").isEmpty)
        XCTAssertEqual(try f.database.fetchCourseTags(courseID: 1, siteID: "b"), otherTags)
    }

    func testTagOnlyModificationStillCompletesWithoutPendingFields() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        let tags = FinderTag.tagData(from: [.init(name: "Review", color: .blue)])
        let result = try SyncedItemModification.apply(
            to: item, changedFields: .tagData, tagData: tags,
            hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertEqual(result.item.tagData, tags)
        XCTAssertTrue(result.stillPendingFields.isEmpty)
    }

    func testContentRenameMoveAndUnrecognizedFieldsRemainRejectedWithoutTagWrites() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        let anchor = try f.database.currentChangeCounter()
        for field: NSFileProviderItemFields in [.contents, .filename, .parentItemIdentifier, .lastUsedDate] {
            assertProviderError(.cannotSynchronize) {
                _ = try SyncedItemModification.apply(
                    to: item, changedFields: [field, .tagData, .contentModificationDate],
                    tagData: FinderTag.tagData(from: [.init(name: "Do not save", color: .red)]),
                    hasNewContents: false, siteID: "a", database: f.database)
            }
        }
        assertProviderError(.cannotSynchronize) {
            _ = try SyncedItemModification.apply(
                to: item, changedFields: .contentModificationDate,
                tagData: nil, hasNewContents: true, siteID: "a", database: f.database)
        }
        XCTAssertEqual(try f.database.fetchItem(id: item.id), item)
        XCTAssertEqual(try f.database.currentChangeCounter(), anchor)
    }

    func testTagStorageFailureDoesNotReturnSuccessfulMetadataResult() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        try providerSQL("CREATE TRIGGER reject_tags BEFORE UPDATE OF tag_data ON items BEGIN SELECT RAISE(ABORT, 'blocked'); END", path: f.path)
        XCTAssertThrowsError(try SyncedItemModification.apply(
            to: item, changedFields: [.tagData, .contentModificationDate],
            tagData: FinderTag.tagData(from: [.init(name: "Review", color: .blue)]),
            hasNewContents: false, siteID: "a", database: f.database))
        XCTAssertEqual(try f.database.fetchItem(id: item.id), item)
    }
}
