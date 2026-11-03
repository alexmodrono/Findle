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

    func testEditedExtendedAttributesSettleWithoutWrites() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        let anchor = try f.database.currentChangeCounter()
        let result = try SyncedItemModification.apply(
            to: item, changedFields: .extendedAttributes,
            tagData: nil, hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertEqual(result.stillPendingFields, .extendedAttributes)
        XCTAssertEqual(try f.database.currentChangeCounter(), anchor)
    }

    func testTaggingAndRenamingChangeTheMetadataVersionButNotTheDate() throws {
        let f = try fixture()
        var item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        item.modificationDate = Date(timeIntervalSince1970: 123)
        try f.database.saveItems([item])
        let before = FileProviderItem(localItem: item).itemVersion

        try f.database.updateItemTagData(id: item.id, tagData: FinderTag.tagData(from: [.init(name: "Review", color: .blue)]))
        let tagged = try XCTUnwrap(f.database.fetchItem(id: item.id))
        XCTAssertEqual(tagged.modificationDate, item.modificationDate)
        let afterTagging = FileProviderItem(localItem: tagged).itemVersion
        XCTAssertNotEqual(afterTagging.metadataVersion, before.metadataVersion)
        XCTAssertEqual(afterTagging.contentVersion, before.contentVersion)

        try f.database.updateItemFilename(id: item.id, filename: "renamed.pdf")
        let renamed = try XCTUnwrap(f.database.fetchItem(id: item.id))
        XCTAssertEqual(renamed.modificationDate, item.modificationDate)
        XCTAssertNotEqual(FileProviderItem(localItem: renamed).itemVersion.metadataVersion, afterTagging.metadataVersion)
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
        for field: NSFileProviderItemFields in [.contents, .filename, .parentItemIdentifier, .creationDate] {
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

    // MARK: - Course folder renames

    private func courseRoot(in f: ProviderFixture, fullName: String = "Operating Systems") throws -> LocalItem {
        let course = MoodleCourse(id: 7, shortName: "OS", fullName: fullName, siteID: "a")
        try f.database.saveCourses([course])
        let root = LocalItem(id: course.rootItemID, siteID: "a", courseID: course.id, remoteID: course.id,
                             filename: course.effectiveFolderName, isDirectory: true)
        try f.database.saveItems([root])
        return root
    }

    func testCourseRootRenameStoresCustomNameAndSanitizedFilename() throws {
        let f = try fixture()
        let root = try courseRoot(in: f)
        let result = try SyncedItemModification.apply(
            to: root, changedFields: .filename, tagData: nil, filename: "OS: Kernels",
            hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertEqual(try f.database.fetchCourse(id: 7, siteID: "a")?.customFolderName, "OS: Kernels")
        XCTAssertEqual(result.item.filename, FileNameSanitizer.sanitize("OS: Kernels"))
        XCTAssertEqual(try f.database.fetchItem(id: root.id)?.filename, result.item.filename)
        XCTAssertTrue(result.stillPendingFields.isEmpty)
    }

    func testCourseRootRenameBackToMoodleNameClearsCustomName() throws {
        let f = try fixture()
        let root = try courseRoot(in: f)
        try f.database.updateCourseCustomFolderName(courseID: 7, siteID: "a", customName: "Kernels")
        let result = try SyncedItemModification.apply(
            to: root, changedFields: .filename, tagData: nil, filename: "Operating Systems",
            hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertNil(try f.database.fetchCourse(id: 7, siteID: "a")?.customFolderName)
        XCTAssertEqual(result.item.filename, "Operating Systems")
    }

    func testCourseRootRenameAndTagsApplyTogether() throws {
        let f = try fixture()
        let root = try courseRoot(in: f)
        let tags = [FinderTag(name: "Exams", color: .red)]
        let result = try SyncedItemModification.apply(
            to: root, changedFields: [.filename, .tagData, .contentModificationDate],
            tagData: FinderTag.tagData(from: tags), filename: "Kernels",
            hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertEqual(result.item.filename, "Kernels")
        XCTAssertEqual(result.item.tagData, FinderTag.tagData(from: tags))
        XCTAssertEqual(try f.database.fetchCourseTags(courseID: 7, siteID: "a"), tags)
        XCTAssertEqual(result.stillPendingFields, .contentModificationDate)
    }

    func testCourseRootRenameOntoAnotherCourseFolderIsACollision() throws {
        let f = try fixture()
        let root = try courseRoot(in: f)
        try f.database.saveCourses([MoodleCourse(id: 8, shortName: "DB", fullName: "Databases", siteID: "a")])
        let anchor = try f.database.currentChangeCounter()
        assertProviderError(.filenameCollision) {
            _ = try SyncedItemModification.apply(
                to: root, changedFields: .filename, tagData: nil, filename: "databases",
                hasNewContents: false, siteID: "a", database: f.database)
        }
        XCTAssertNil(try f.database.fetchCourse(id: 7, siteID: "a")?.customFolderName)
        XCTAssertEqual(try f.database.fetchItem(id: root.id), root)
        XCTAssertEqual(try f.database.currentChangeCounter(), anchor)
    }

    func testCourseRootMoveIsStillRejected() throws {
        let f = try fixture()
        let root = try courseRoot(in: f)
        assertProviderError(.cannotSynchronize) {
            _ = try SyncedItemModification.apply(
                to: root, changedFields: [.filename, .parentItemIdentifier], tagData: nil, filename: "Kernels",
                hasNewContents: false, siteID: "a", database: f.database)
        }
        XCTAssertNil(try f.database.fetchCourse(id: 7, siteID: "a")?.customFolderName)
    }

    func testOnlyCourseRootsAdvertiseRenaming() throws {
        let f = try fixture()
        let root = try courseRoot(in: f)
        let section = LocalItem(id: "section-a-7-1", parentID: root.id, siteID: "a", courseID: 7, remoteID: 1,
                                filename: "Week 1", isDirectory: true)
        let file = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        XCTAssertTrue(FileProviderItem(localItem: root).capabilities.contains(.allowsRenaming))
        XCTAssertFalse(FileProviderItem(localItem: root).capabilities.contains(.allowsReparenting))
        XCTAssertFalse(FileProviderItem(localItem: section).capabilities.contains(.allowsRenaming))
        XCTAssertFalse(FileProviderItem(localItem: file).capabilities.contains(.allowsRenaming))
    }

    func testOpeningAnItemRecordsTheVisitAndSettlesTheField() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        let arrived = Date(timeIntervalSince1970: 1_000)
        try f.database.commitCourseSync(
            items: [item], deletingItemIDs: [],
            cursor: SyncCursor(courseID: 1, siteID: "a", lastSyncDate: arrived, itemCount: 1),
            outline: CourseOutlineSnapshot(courseID: 1, capturedAt: arrived, sections: []), arrivedItemIDs: [item.id])
        XCTAssertEqual(try f.database.fetchNewItems(courseID: 1, siteID: "a").map(\.id), [item.id])
        let anchor = try f.database.currentChangeCounter()

        let opened = arrived.addingTimeInterval(60)
        let result = try SyncedItemModification.apply(
            to: item, changedFields: [.lastUsedDate, .contentModificationDate],
            tagData: nil, lastUsedDate: opened, hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertEqual(result.stillPendingFields, .contentModificationDate, "Only the unsupported timestamp stays pending")
        XCTAssertEqual(result.item.lastUsedDate ?? nil, opened, "The system's replica keeps the date it reported")
        XCTAssertEqual(try f.database.fetchNewItems(courseID: 1, siteID: "a"), [])
        XCTAssertTrue(result.badgesChanged, "The visit clears the new badge, which Finder needs to hear about")
        XCTAssertNil(result.item.decorations ?? nil)
        XCTAssertGreaterThan(try f.database.currentChangeCounter(), anchor)

        let settled = try f.database.currentChangeCounter()
        let again = try SyncedItemModification.apply(
            to: item, changedFields: .lastUsedDate,
            tagData: nil, lastUsedDate: opened.addingTimeInterval(60), hasNewContents: false, siteID: "a", database: f.database)
        XCTAssertFalse(again.badgesChanged)
        XCTAssertEqual(try f.database.currentChangeCounter(), settled, "Visiting something already seen changes nothing")
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
