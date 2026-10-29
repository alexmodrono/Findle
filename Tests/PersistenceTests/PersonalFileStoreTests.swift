// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
import CryptoKit
@testable import FindlePersistence
@testable import SharedDomain

final class PersonalFileStoreTests: XCTestCase {
    private var tempRoot: URL!
    private var storeRoot: URL!
    private var database: Database!

    private let siteID = "site-1"
    private let siteName = "Test University"
    private let courseAnchor = PersonalFileStore.Anchor(
        itemID: "course-site-1-7", parentItemID: nil, courseID: 7, name: "Biology"
    )
    private let sectionAnchor = PersonalFileStore.Anchor(
        itemID: "section-site-1-7-2", parentItemID: "course-site-1-7", courseID: 7, name: "Week 1"
    )

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonalFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        storeRoot = tempRoot.appendingPathComponent("Personal Files", isDirectory: true)
        database = try Database(path: tempRoot.appendingPathComponent("test.db").path)
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Helpers

    private func makeStore() -> PersonalFileStore {
        PersonalFileStore(rootURL: storeRoot)
    }

    private func makeReconciler() -> PersonalFilesReconciler {
        PersonalFilesReconciler(store: makeStore(), database: database)
    }

    private func reconcile() throws -> Bool {
        try makeReconciler().reconcile(siteID: siteID, siteName: siteName)
    }

    /// Stores an enabled course row, as the sync engine would after a course sync.
    private func saveCourse(id: Int, enabled: Bool = true) throws {
        try database.saveCourses([
            MoodleCourse(id: id, shortName: "C\(id)", fullName: "Course \(id)", siteID: siteID, isSyncEnabled: enabled)
        ])
    }

    /// `/var` and `/private/var` name the same temp directory; compare resolved paths.
    private func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func writeFile(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func fetch(_ id: String) throws -> LocalItem {
        let row = try database.fetchItem(id: id)
        return try XCTUnwrap(row, "expected a row for \(id)")
    }

    // MARK: - Site and anchor directories

    func testSiteDirectoryReusesMarkerAndSuffixesCollisions() throws {
        let store = makeStore()

        let first = try store.siteDirectory(siteID: "site-A", siteName: "Campus")
        XCTAssertEqual(first.lastPathComponent, "Campus")
        XCTAssertTrue(FileManager.default.fileExists(atPath: storeRoot.appendingPathComponent("README.txt").path))

        let renamed = try store.siteDirectory(siteID: "site-A", siteName: "Campus Renamed")
        XCTAssertEqual(canonical(renamed), canonical(first), "A site is found by its marker, not its name")

        let second = try store.siteDirectory(siteID: "site-B", siteName: "Campus")
        XCTAssertEqual(second.lastPathComponent, "Campus 2")

        try FileManager.default.createDirectory(
            at: storeRoot.appendingPathComponent("Other", isDirectory: true),
            withIntermediateDirectories: true
        )
        let third = try store.siteDirectory(siteID: "site-C", siteName: "Other")
        XCTAssertEqual(third.lastPathComponent, "Other 2", "A folder without a marker still counts as taken")
    }

    func testAnchorDirectoryCreatesMarkersAndReusesByItemIDAfterRename() throws {
        let store = makeStore()

        let first = try store.anchorDirectory(chain: [courseAnchor, sectionAnchor], siteID: siteID, siteName: siteName)
        let courseDirectory = first.deletingLastPathComponent()
        XCTAssertEqual(courseDirectory.lastPathComponent, "Biology")
        XCTAssertEqual(first.lastPathComponent, "Week 1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: courseDirectory.appendingPathComponent(".findle-anchor.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.appendingPathComponent(".findle-anchor.json").path))

        let renamedSection = PersonalFileStore.Anchor(
            itemID: sectionAnchor.itemID, parentItemID: courseAnchor.itemID, courseID: 7, name: "Week One"
        )
        let second = try store.anchorDirectory(chain: [courseAnchor, renamedSection], siteID: siteID, siteName: siteName)
        XCTAssertEqual(canonical(second), canonical(first), "The section is matched by itemID, so its folder is reused")

        let markerData = try Data(contentsOf: second.appendingPathComponent(".findle-anchor.json"))
        let marker = try JSONDecoder().decode(PersonalFileStore.Anchor.self, from: markerData)
        XCTAssertEqual(marker, renamedSection, "The marker is rewritten with the new name")
    }

    func testDirectoryForMoodleParentBuildsAnchorChainFromRows() throws {
        try database.saveItems([
            LocalItem(id: courseAnchor.itemID, parentID: nil, siteID: siteID, courseID: 7, remoteID: 7,
                      filename: "Biology", isDirectory: true, syncState: .materialized),
            LocalItem(id: sectionAnchor.itemID, parentID: courseAnchor.itemID, siteID: siteID, courseID: 7, remoteID: 2,
                      filename: "Week 1", isDirectory: true, syncState: .materialized),
        ])
        let store = makeStore()

        let directory = try store.directory(
            forParentID: sectionAnchor.itemID, siteID: siteID, siteName: siteName, database: database
        )

        XCTAssertEqual(directory.lastPathComponent, "Week 1")
        XCTAssertEqual(directory.deletingLastPathComponent().lastPathComponent, "Biology")
        let marker = try JSONDecoder().decode(
            PersonalFileStore.Anchor.self,
            from: Data(contentsOf: directory.appendingPathComponent(".findle-anchor.json"))
        )
        XCTAssertEqual(marker, sectionAnchor)
    }

    func testUniqueURLAddsNumberBeforeExtension() throws {
        let store = makeStore()
        let directory = storeRoot.appendingPathComponent("Dir", isDirectory: true)
        try writeFile("a", to: directory.appendingPathComponent("notes.pdf"))

        XCTAssertEqual(store.uniqueURL(for: "notes.pdf", in: directory).lastPathComponent, "notes 2.pdf")
        XCTAssertEqual(store.uniqueURL(for: "other.pdf", in: directory).lastPathComponent, "other.pdf")
    }

    // MARK: - Extended attributes

    func testItemIDExtendedAttributeRoundTrip() throws {
        let file = tempRoot.appendingPathComponent("attr.txt")
        try writeFile("content", to: file)

        XCTAssertNil(PersonalFileStore.itemID(at: file))
        try PersonalFileStore.setItemID("local-ABC", at: file)
        XCTAssertEqual(PersonalFileStore.itemID(at: file), "local-ABC")
        try PersonalFileStore.setItemID("local-DEF", at: file)
        XCTAssertEqual(PersonalFileStore.itemID(at: file), "local-DEF")

        let folder = tempRoot.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try PersonalFileStore.setItemID("local-FOLDER", at: folder)
        XCTAssertEqual(PersonalFileStore.itemID(at: folder), "local-FOLDER")
    }

    // MARK: - Reconciliation

    func testReconcileImportsFileUnderAnchorDirectory() throws {
        try saveCourse(id: 7)
        let directory = try makeStore().anchorDirectory(chain: [courseAnchor], siteID: siteID, siteName: siteName)
        let file = directory.appendingPathComponent("notes.txt")
        try writeFile("hello", to: file)

        XCTAssertTrue(try reconcile())

        let id = try XCTUnwrap(PersonalFileStore.itemID(at: file))
        XCTAssertTrue(id.hasPrefix("local-"))
        let row = try fetch(id)
        XCTAssertEqual(row.parentID, courseAnchor.itemID)
        XCTAssertEqual(row.courseID, 7)
        XCTAssertEqual(row.filename, "notes.txt")
        XCTAssertEqual(row.fileSize, 5)
        XCTAssertFalse(row.isDirectory)
        XCTAssertTrue(row.isLocal)
        XCTAssertEqual(row.syncState, .materialized)

        let standIn = try fetch(courseAnchor.itemID)
        XCTAssertTrue(standIn.isDirectory)
        XCTAssertTrue(standIn.isLocal)
        XCTAssertEqual(standIn.filename, "Biology")
    }

    func testSecondReconcileWithoutChangesReturnsFalse() throws {
        try saveCourse(id: 7)
        let directory = try makeStore().anchorDirectory(chain: [courseAnchor], siteID: siteID, siteName: siteName)
        try writeFile("hello", to: directory.appendingPathComponent("notes.txt"))

        XCTAssertTrue(try reconcile())
        XCTAssertFalse(try reconcile())
    }

    func testFileRemovedFromDiskHasRowDeleted() throws {
        try saveCourse(id: 7)
        let directory = try makeStore().anchorDirectory(chain: [courseAnchor], siteID: siteID, siteName: siteName)
        let file = directory.appendingPathComponent("notes.txt")
        try writeFile("hello", to: file)
        XCTAssertTrue(try reconcile())
        let id = try XCTUnwrap(PersonalFileStore.itemID(at: file))

        try FileManager.default.removeItem(at: file)

        XCTAssertTrue(try reconcile())
        let remaining = try database.fetchItem(id: id)
        XCTAssertNil(remaining)
    }

    func testDatabaseWipeRecreatesStandInsAndFilesWithSameIDs() throws {
        let directory = try makeStore().anchorDirectory(chain: [courseAnchor], siteID: siteID, siteName: siteName)
        let file = directory.appendingPathComponent("notes.txt")
        try writeFile("hello", to: file)
        XCTAssertTrue(try reconcile())
        let originalID = try XCTUnwrap(PersonalFileStore.itemID(at: file))

        database = try Database(path: tempRoot.appendingPathComponent("fresh.db").path)
        XCTAssertNil(try database.fetchItem(id: originalID))

        XCTAssertTrue(try reconcile())

        let standIn = try fetch(courseAnchor.itemID)
        XCTAssertTrue(standIn.isDirectory)
        let row = try fetch(originalID)
        XCTAssertEqual(row.parentID, courseAnchor.itemID)
        XCTAssertEqual(row.filename, "notes.txt")
        XCTAssertEqual(PersonalFileStore.itemID(at: file), originalID)
    }

    func testLegacyMigrationCopiesFileIntoStoreAndKeepsRecoveryOriginal() throws {
        let outside = tempRoot.appendingPathComponent("Old Location", isDirectory: true)
        let legacyFile = outside.appendingPathComponent("legacy.txt")
        try writeFile("legacy", to: legacyFile)
        let legacyID = "local-legacy-\(UUID().uuidString)"
        try database.saveItems([
            LocalItem(id: legacyID, parentID: nil, siteID: siteID, courseID: 0, remoteID: 0,
                      filename: "legacy.txt", isDirectory: false, fileSize: 6,
                      syncState: .materialized, localPath: legacyFile.path, isLocal: true),
        ])

        XCTAssertTrue(try reconcile())

        let row = try fetch(legacyID)
        let newPath = try XCTUnwrap(row.localPath)
        let canonicalRoot = storeRoot.resolvingSymlinksInPath().path
        XCTAssertTrue(URL(fileURLWithPath: newPath).resolvingSymlinksInPath().path.hasPrefix(canonicalRoot + "/"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertEqual(PersonalFileStore.itemID(at: URL(fileURLWithPath: newPath)), legacyID)
    }

    func testDuplicatedIDAttributeGivesCopyANewID() throws {
        try saveCourse(id: 7)
        let directory = try makeStore().anchorDirectory(chain: [courseAnchor], siteID: siteID, siteName: siteName)
        // Names are chosen so the original sorts first in the scan.
        let original = directory.appendingPathComponent("alpha.txt")
        try writeFile("original", to: original)
        XCTAssertTrue(try reconcile())
        let originalID = try XCTUnwrap(PersonalFileStore.itemID(at: original))

        let copy = directory.appendingPathComponent("beta.txt")
        try FileManager.default.copyItem(at: original, to: copy)
        try PersonalFileStore.setItemID(originalID, at: copy)

        XCTAssertTrue(try reconcile())

        let copyID = try XCTUnwrap(PersonalFileStore.itemID(at: copy))
        XCTAssertNotEqual(copyID, originalID)
        XCTAssertTrue(copyID.hasPrefix("local-"))
        XCTAssertEqual(PersonalFileStore.itemID(at: original), originalID)
        XCTAssertEqual(try fetch(originalID).filename, "alpha.txt")
        XCTAssertEqual(try fetch(copyID).filename, "beta.txt")
    }

    // MARK: - Recovery and incomplete filesystem operations

    private func reconcile(files: PersonalFileStore.FileOperations) throws -> Bool {
        try PersonalFilesReconciler(store: PersonalFileStore(rootURL: storeRoot, files: files), database: database)
            .reconcile(siteID: siteID, siteName: siteName)
    }

    private func hash(_ url: URL) throws -> [UInt8] {
        Array(SHA256.hash(data: try Data(contentsOf: url)))
    }

    private func trackedFile(named name: String = "notes.txt") throws -> (url: URL, id: String) {
        try saveCourse(id: 7)
        let directory = try makeStore().anchorDirectory(chain: [courseAnchor], siteID: siteID, siteName: siteName)
        let file = directory.appendingPathComponent(name)
        try writeFile("personal contents", to: file)
        _ = try reconcile()
        return (file, try XCTUnwrap(PersonalFileStore.itemID(at: file)))
    }

    private func legacyFile(named name: String) throws -> (url: URL, id: String) {
        let url = tempRoot.appendingPathComponent("Legacy").appendingPathComponent(name)
        try writeFile("original \(name)", to: url)
        let id = "local-legacy-\(name)"
        try database.saveItems([LocalItem(id: id, siteID: siteID, courseID: 0, remoteID: 0,
            filename: name, localPath: url.path, isLocal: true)])
        return (url, id)
    }

    func testProviderRecoveryPreservesLateWritesToOriginalInodeAndUnindexedChildren() throws {
        let provider = tempRoot.appendingPathComponent("Provider", isDirectory: true)
        let legacy = provider.appendingPathComponent(".FindleState/LocalContent", isDirectory: true)
        let original = legacy.appendingPathComponent("notes.txt")
        let unindexed = legacy.appendingPathComponent("unindexed.txt")
        try writeFile("original", to: original)
        try writeFile("unindexed original", to: unindexed)
        let handle = try FileHandle(forWritingTo: original)
        defer { try? handle.close() }
        let inode = try FileManager.default.attributesOfItem(atPath: original.path)[.systemFileNumber] as? NSNumber
        try database.saveItems([LocalItem(id: "local-recovery", siteID: siteID, courseID: 0, remoteID: 0,
            filename: "notes.txt", localPath: original.path, isLocal: true)])
        let archive = storeRoot.appendingPathComponent("Recovery", isDirectory: true)
        try PersonalFileRecovery.prepare(database: database, store: makeStore(), siteID: siteID,
            siteName: siteName, archiveRoot: archive, providerStateRoot: provider)
        let relocated = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: archive,
            includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix("original-") })
        let relocatedFile = relocated.appendingPathComponent("notes.txt")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: relocatedFile.path)[.systemFileNumber] as? NSNumber, inode)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("saved after recovery".utf8))
        try handle.synchronize()
        // This is only a disposable test directory, never an installed domain.
        try FileManager.default.removeItem(at: provider)
        XCTAssertEqual(try String(contentsOf: relocatedFile, encoding: .utf8), "saved after recovery")
        XCTAssertEqual(try String(contentsOf: relocated.appendingPathComponent("unindexed.txt"), encoding: .utf8), "unindexed original")
        let managed = URL(fileURLWithPath: try XCTUnwrap(fetch("local-recovery").localPath))
        XCTAssertEqual(try String(contentsOf: managed, encoding: .utf8), "original")
        // Interrupted reset replay never replaces the preserved originals.
        try PersonalFileRecovery.prepare(database: database, store: makeStore(), siteID: siteID,
            siteName: siteName, archiveRoot: archive, providerStateRoot: provider)
        XCTAssertEqual(try String(contentsOf: relocatedFile, encoding: .utf8), "saved after recovery")
    }

    func testProviderRecoveryRelocationFailureLeavesOriginalAvailable() throws {
        let provider = tempRoot.appendingPathComponent("Provider", isDirectory: true)
        let original = provider.appendingPathComponent(".FindleState/LocalContent/notes.txt")
        try writeFile("only original", to: original)
        try database.saveItems([LocalItem(id: "local-recovery", siteID: siteID, courseID: 0, remoteID: 0,
            filename: "notes.txt", localPath: original.path, isLocal: true)])
        XCTAssertThrowsError(try PersonalFileRecovery.prepare(database: database, store: makeStore(), siteID: siteID,
            siteName: siteName, archiveRoot: storeRoot.appendingPathComponent("Recovery"), providerStateRoot: provider,
            operations: .init(relocate: { _, _ in throw POSIXError(.EXDEV) })))
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "only original")
        let managed = URL(fileURLWithPath: try XCTUnwrap(fetch("local-recovery").localPath))
        XCTAssertEqual(try String(contentsOf: managed, encoding: .utf8), "only original")
    }

    func testProviderRecoveryRejectsUnknownProviderLocalLayoutWithoutMovingOriginal() throws {
        let provider = tempRoot.appendingPathComponent("Provider", isDirectory: true)
        let original = provider.appendingPathComponent("unknown/notes.txt")
        try writeFile("only original", to: original)
        try database.saveItems([LocalItem(id: "local-recovery", siteID: siteID, courseID: 0, remoteID: 0,
            filename: "notes.txt", localPath: original.path, isLocal: true)])
        let before = try fetch("local-recovery")
        XCTAssertThrowsError(try PersonalFileRecovery.prepare(database: database, store: makeStore(), siteID: siteID,
            siteName: siteName, archiveRoot: storeRoot.appendingPathComponent("Recovery"), providerStateRoot: provider))
        XCTAssertEqual(try fetch("local-recovery"), before)
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "only original")
    }

    func testProviderRecoveryRejectsMissingFilesAndArchiveInsideRemovedRoot() throws {
        let legacy = try legacyFile(named: "missing.txt")
        let before = try fetch(legacy.id)
        try FileManager.default.removeItem(at: legacy.url)
        XCTAssertThrowsError(try PersonalFileRecovery.prepare(database: database, store: makeStore(), siteID: siteID,
            siteName: siteName, archiveRoot: storeRoot.appendingPathComponent("Recovery")))
        XCTAssertEqual(try fetch(legacy.id), before)
        for archive in [tempRoot!, tempRoot.appendingPathComponent("inside")] {
            XCTAssertThrowsError(try PersonalFileRecovery.prepare(database: database, store: makeStore(), siteID: siteID,
                siteName: siteName, archiveRoot: archive, providerStateRoot: tempRoot))
        }
    }

    func testUnreadableEntryStopsDeletionOfOtherMissingFiles() throws {
        let kept = try trackedFile(named: "kept.txt")
        let missing = try trackedFile(named: "missing.txt")
        let before = try database.fetchLocalItems(siteID: siteID)
        let anchor = try database.currentChangeCounter()
        try FileManager.default.removeItem(at: missing.url)
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.attributes = { url in
            if url.lastPathComponent == "kept.txt" { throw POSIXError(.EACCES) }
            return try live.attributes(url)
        }
        XCTAssertThrowsError(try reconcile(files: files))
        XCTAssertEqual(try database.fetchLocalItems(siteID: siteID), before)
        XCTAssertEqual(try database.currentChangeCounter(), anchor)
        XCTAssertEqual(PersonalFileStore.itemID(at: kept.url), kept.id)
        XCTAssertTrue(try database.fetchPendingDeletions().isEmpty)
        _ = try reconcile()
        XCTAssertNil(try database.fetchItem(id: missing.id), "A later complete scan may confirm a real deletion")
    }

    func testMissingAndUnavailableStoreKeepExistingIdentities() throws {
        let file = try trackedFile()
        let digest = try hash(file.url)
        let before = try fetch(file.id)
        let moved = tempRoot.appendingPathComponent("Offline store")
        try FileManager.default.moveItem(at: storeRoot, to: moved)
        XCTAssertFalse(try reconcile())
        XCTAssertEqual(try fetch(file.id), before)
        try FileManager.default.moveItem(at: moved, to: storeRoot)
        var files = PersonalFileStore.FileOperations()
        files.children = { _ in throw POSIXError(.EACCES) }
        XCTAssertThrowsError(try reconcile(files: files))
        XCTAssertEqual(try fetch(file.id), before)
        XCTAssertEqual(try hash(file.url), digest)
    }

    func testSiteDisappearingDuringScanIsNotAnEmptySnapshot() throws {
        let file = try trackedFile()
        let before = try fetch(file.id)
        let directory = try XCTUnwrap(makeStore().existingSiteDirectory(siteID: siteID))
        let moved = tempRoot.appendingPathComponent("Temporarily unavailable")
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.children = { url in
            if url == directory {
                try FileManager.default.moveItem(at: directory, to: moved)
                return []
            }
            return try live.children(url)
        }
        XCTAssertThrowsError(try reconcile(files: files))
        XCTAssertEqual(try fetch(file.id), before)
        XCTAssertTrue(try database.fetchPendingDeletions().isEmpty)
        try FileManager.default.moveItem(at: moved, to: directory)
        XCTAssertFalse(try reconcile())
    }

    func testCorruptMarkersNeverReclassifyAnchorsOrDeleteRows() throws {
        let file = try trackedFile()
        let digest = try hash(file.url)
        let directory = file.url.deletingLastPathComponent()
        let markers = [directory.appendingPathComponent(".findle-anchor.json"),
                       directory.deletingLastPathComponent().appendingPathComponent(".findle-site.json")]
        for marker in markers {
            let original = try Data(contentsOf: marker)
            let before = try database.fetchLocalItems(siteID: siteID)
            try Data("{corrupt".utf8).write(to: marker)
            XCTAssertThrowsError(try reconcile())
            XCTAssertEqual(try database.fetchLocalItems(siteID: siteID), before)
            XCTAssertEqual(PersonalFileStore.itemID(at: file.url), file.id)
            XCTAssertEqual(try hash(file.url), digest)
            try original.write(to: marker)
        }
    }

    func testUnavailableAttributesAndFailedIdentityWritesDoNotPublishFreshIDs() throws {
        let file = try trackedFile()
        let before = try fetch(file.id)
        var files = PersonalFileStore.FileOperations()
        files.readID = { url in
            throw PersonalFileStoreError.extendedAttributeReadFailed(path: url.path, errno: ENOTSUP)
        }
        XCTAssertThrowsError(try reconcile(files: files))
        XCTAssertEqual(try fetch(file.id), before)

        let untracked = file.url.deletingLastPathComponent().appendingPathComponent("new.txt")
        try writeFile("new contents", to: untracked)
        files = PersonalFileStore.FileOperations()
        files.writeID = { _, url in
            throw PersonalFileStoreError.extendedAttributeWriteFailed(path: url.path, errno: ENOSPC)
        }
        XCTAssertThrowsError(try reconcile(files: files))
        XCTAssertEqual(try fetch(file.id), before)
        XCTAssertNil(PersonalFileStore.itemID(at: untracked))
        XCTAssertEqual(try database.fetchLocalItems(siteID: siteID).filter { $0.id.hasPrefix("local-") }.count, 1)
        XCTAssertTrue(try database.fetchPendingDeletions().isEmpty)
        _ = try reconcile()
        XCTAssertNotNil(PersonalFileStore.itemID(at: untracked))
    }

    func testRemovedIdentityAttributeIsRestoredFromExistingPath() throws {
        let file = try trackedFile()
        var files = PersonalFileStore.FileOperations()
        files.readID = { _ in nil }
        _ = try reconcile(files: files)
        XCTAssertEqual(PersonalFileStore.itemID(at: file.url), file.id)
        XCTAssertNotNil(try database.fetchItem(id: file.id))
        XCTAssertTrue(try database.fetchPendingDeletions().isEmpty)
    }

    func testCopiedAttributeCannotStealOriginalIdentityBySortingFirst() throws {
        let original = try trackedFile(named: "z-original.txt")
        let copy = original.url.deletingLastPathComponent().appendingPathComponent("a-copy.txt")
        try FileManager.default.copyItem(at: original.url, to: copy)
        _ = try reconcile()
        XCTAssertEqual(PersonalFileStore.itemID(at: original.url), original.id)
        XCTAssertNotEqual(PersonalFileStore.itemID(at: copy), original.id)
        XCTAssertEqual(try fetch(original.id).filename, original.url.lastPathComponent)
        XCTAssertEqual(try hash(copy), try hash(original.url))
    }

    func testFailedLegacyCopyAndRenamePreserveOriginalAndReplay() throws {
        for phase in ["before-copy", "after-copy", "before-rename", "after-rename"] {
            let legacy = try legacyFile(named: phase + ".txt")
            let digest = try hash(legacy.url)
            let live = PersonalFileStore.FileOperations()
            var files = live
            files.copy = { source, target in
                if phase == "before-copy" { throw POSIXError(.ENOSPC) }
                try live.copy(source, target)
                if phase == "after-copy" { throw POSIXError(.ENOSPC) }
            }
            files.move = { source, target in
                if phase == "before-rename" { throw POSIXError(.EIO) }
                try live.move(source, target)
                if phase == "after-rename" { throw POSIXError(.EIO) }
            }
            _ = try reconcile(files: files)
            XCTAssertEqual(try hash(legacy.url), digest, phase)
            _ = try reconcile()
            let destination = URL(fileURLWithPath: try XCTUnwrap(fetch(legacy.id).localPath))
            XCTAssertNotEqual(canonical(destination), canonical(legacy.url))
            XCTAssertEqual(try hash(destination), digest, phase)
            XCTAssertEqual(try hash(legacy.url), digest, phase)
            XCTAssertEqual(PersonalFileStore.itemID(at: destination), legacy.id)
            XCTAssertEqual(try makeStore().scan(siteID: siteID).filter { $0.storedItemID == legacy.id }.count, 1)
            XCTAssertFalse(try reconcile(), "Repeating a completed migration creates no duplicates")
        }
    }

    func testFailedDirectoryIdentityWriteKeepsConcurrentChild() throws {
        let oldDirectory = tempRoot.appendingPathComponent("Legacy folder")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        try database.saveItems([LocalItem(id: "local-directory", siteID: siteID, courseID: 0, remoteID: 0,
            filename: "Personal folder", isDirectory: true, localPath: oldDirectory.path, isLocal: true)])
        var files = PersonalFileStore.FileOperations()
        files.writeID = { _, url in
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                try Data("arrived during migration".utf8).write(to: url.appendingPathComponent("new.txt"))
            }
            throw POSIXError(.ENOSPC)
        }
        XCTAssertThrowsError(try reconcile(files: files))
        let siteDirectory = try XCTUnwrap(makeStore().existingSiteDirectory(siteID: siteID))
        let arriving = siteDirectory.appendingPathComponent("Personal folder/new.txt")
        XCTAssertEqual(try String(contentsOf: arriving, encoding: .utf8), "arrived during migration")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldDirectory.path))
        _ = try reconcile()
        XCTAssertEqual(try String(contentsOf: arriving, encoding: .utf8), "arrived during migration")
    }

    func testLegacyDestinationSurvivesDatabaseFailureAndIsAdoptedOnReplay() throws {
        let legacy = try legacyFile(named: "database-failure.txt")
        let digest = try hash(legacy.url)
        try database.execute("CREATE TRIGGER fail_migration BEFORE INSERT ON items WHEN NEW.is_local = 1 BEGIN SELECT RAISE(ABORT, 'injected failure'); END")
        XCTAssertThrowsError(try reconcile())
        XCTAssertEqual(try fetch(legacy.id).localPath, legacy.url.path)
        let copied = try XCTUnwrap(makeStore().scan(siteID: siteID).first { $0.storedItemID == legacy.id })
        XCTAssertEqual(try hash(copied.url), digest)
        XCTAssertEqual(try hash(legacy.url), digest)
        try database.execute("DROP TRIGGER fail_migration")
        _ = try reconcile()
        XCTAssertEqual(canonical(URL(fileURLWithPath: try XCTUnwrap(fetch(legacy.id).localPath))), canonical(copied.url))
        XCTAssertEqual(try makeStore().scan(siteID: siteID).filter { $0.storedItemID == legacy.id }.count, 1)
    }

    func testLegacyEditsDuringCopyRetainBothVersions() throws {
        let legacy = try legacyFile(named: "live-edit.txt")
        let originalHash = try hash(legacy.url)
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.copy = { source, target in
            try live.copy(source, target)
            try Data("edit saved during migration".utf8).write(to: source)
        }
        _ = try reconcile(files: files)
        let destination = URL(fileURLWithPath: try XCTUnwrap(fetch(legacy.id).localPath))
        XCTAssertEqual(try hash(destination), originalHash)
        XCTAssertEqual(try String(contentsOf: legacy.url, encoding: .utf8), "edit saved during migration")
        XCTAssertNotEqual(try hash(legacy.url), originalHash)
        XCTAssertEqual(PersonalFileStore.itemID(at: destination), legacy.id)
    }

    func testLegacyMigrationDoesNotOverwriteFinderChangesDuringCopy() throws {
        let legacy = try legacyFile(named: "concurrent-migration.txt")
        let digest = try hash(legacy.url)
        let latest = tempRoot.appendingPathComponent("Finder-new-version.txt")
        try writeFile("newer Finder contents", to: latest)
        var updated = try fetch(legacy.id)
        updated.tagData = Data("concurrent Finder tags".utf8)
        updated.isPinned = true
        updated.localPath = latest.path
        let concurrentRow = updated
        let writer = try Database(path: database.filePath)
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.copy = { source, target in
            try live.copy(source, target)
            try writer.saveItems([concurrentRow])
        }
        _ = try reconcile(files: files)
        XCTAssertEqual(try fetch(legacy.id), concurrentRow)
        XCTAssertEqual(try hash(legacy.url), digest)
        XCTAssertEqual(try String(contentsOf: latest, encoding: .utf8), "newer Finder contents")
        let copy = try XCTUnwrap(makeStore().scan(siteID: siteID).first { $0.storedItemID == legacy.id })
        XCTAssertEqual(try hash(copy.url), digest)
        XCTAssertTrue(try database.fetchPendingDeletions().isEmpty)
    }

    func testFailureAfterMigrationCommitKeepsPublishedAndRecoveryCopies() throws {
        let legacy = try legacyFile(named: "after-commit.txt")
        let digest = try hash(legacy.url)
        var files = PersonalFileStore.FileOperations()
        files.readID = { _ in throw POSIXError(.EIO) }
        XCTAssertThrowsError(try reconcile(files: files))
        let destination = URL(fileURLWithPath: try XCTUnwrap(fetch(legacy.id).localPath))
        XCTAssertNotEqual(canonical(destination), canonical(legacy.url))
        XCTAssertEqual(try hash(destination), digest)
        XCTAssertEqual(try hash(legacy.url), digest)
        _ = try reconcile()
        XCTAssertEqual(PersonalFileStore.itemID(at: destination), legacy.id)
    }

    func testConcurrentDirectoryEditAbortsDeletionAndKeepsNewFile() throws {
        let existing = try trackedFile()
        let missing = try trackedFile(named: "deleted.txt")
        try FileManager.default.removeItem(at: missing.url)
        let arriving = existing.url.deletingLastPathComponent().appendingPathComponent("arriving.txt")
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.children = { url in
            let entries = try live.children(url)
            if url.resolvingSymlinksInPath().path == arriving.deletingLastPathComponent().resolvingSymlinksInPath().path {
                try Data("concurrent edit".utf8).write(to: arriving)
            }
            return entries
        }
        XCTAssertThrowsError(try reconcile(files: files))
        XCTAssertNotNil(try database.fetchItem(id: missing.id))
        XCTAssertEqual(try String(contentsOf: arriving, encoding: .utf8), "concurrent edit")
        XCTAssertEqual(PersonalFileStore.itemID(at: existing.url), existing.id)
        _ = try reconcile()
        XCTAssertNotNil(PersonalFileStore.itemID(at: arriving))
    }

    func testFinderRowArrivingAfterScanStartsIsNotDeleted() throws {
        let existing = try trackedFile()
        let destination = existing.url.deletingLastPathComponent().appendingPathComponent("arriving.txt")
        let arriving = LocalItem(id: "local-arriving", parentID: courseAnchor.itemID, siteID: siteID,
            courseID: 7, remoteID: 0, filename: "arriving.txt", localPath: destination.path, isLocal: true)
        let writer = try XCTUnwrap(database)
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.readID = { url in
            // Finder has registered the item but has not delivered its contents yet.
            try writer.saveItems([arriving])
            return try live.readID(url)
        }
        _ = try reconcile(files: files)
        XCTAssertEqual(try fetch(arriving.id), arriving)
        XCTAssertFalse(try database.fetchPendingDeletions().contains(arriving.id))
        try writeFile("new Finder contents", to: destination)
        _ = try reconcile()
        XCTAssertEqual(PersonalFileStore.itemID(at: destination), arriving.id)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "new Finder contents")
    }

    func testChildInsertedAtDeletionCommitBoundaryKeepsParentAndChild() throws {
        try saveCourse(id: 7)
        let anchorDirectory = try makeStore().anchorDirectory(chain: [courseAnchor], siteID: siteID, siteName: siteName)
        let directory = anchorDirectory.appendingPathComponent("Personal")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        _ = try reconcile()
        let parentID = try XCTUnwrap(PersonalFileStore.itemID(at: directory))
        let expectedParent = try fetch(parentID)
        try FileManager.default.removeItem(at: directory)
        let arriving = LocalItem(id: "local-precommit-child", parentID: parentID, siteID: siteID,
            courseID: 7, remoteID: 0, filename: "new.txt", localPath: directory.appendingPathComponent("new.txt").path, isLocal: true)
        let writer = try Database(path: database.filePath)
        let boundary = ReconciliationBoundary()
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.attributes = { url in
            if url.lastPathComponent == "Personal" {
                boundary.arm()
            } else {
                // The candidate's absent path was checked already. This fires
                // inside the final validation, immediately before BEGIN IMMEDIATE.
                try boundary.runOnce { try writer.saveItems([arriving]) }
            }
            return try live.attributes(url)
        }
        _ = try reconcile(files: files)
        XCTAssertTrue(boundary.fired)
        XCTAssertEqual(try fetch(parentID), expectedParent)
        XCTAssertEqual(try fetch(arriving.id), arriving)
        XCTAssertFalse(try database.fetchPendingDeletions().contains(parentID))
        XCTAssertFalse(try database.fetchPendingDeletions().contains(arriving.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: anchorDirectory.appendingPathComponent(".findle-anchor.json").path))
    }

    func testRowEditedAtDeletionCommitBoundaryIsNotTombstoned() throws {
        let existing = try trackedFile()
        var updated = try fetch(existing.id)
        updated.tagData = Data("Finder tags saved after the scan".utf8)
        updated.isPinned = true
        try FileManager.default.removeItem(at: existing.url)
        let concurrentRow = updated
        let writer = try Database(path: database.filePath)
        let boundary = ReconciliationBoundary()
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.attributes = { url in
            if url.lastPathComponent == existing.url.lastPathComponent {
                boundary.arm()
            } else {
                try boundary.runOnce { try writer.saveItems([concurrentRow]) }
            }
            return try live.attributes(url)
        }
        _ = try reconcile(files: files)
        XCTAssertTrue(boundary.fired)
        XCTAssertEqual(try fetch(existing.id), concurrentRow)
        XCTAssertFalse(try database.fetchPendingDeletions().contains(existing.id))
    }

    func testImportDoesNotOverwriteFinderMetadataAtSaveBoundary() throws {
        let existing = try trackedFile()
        try writeFile("new disk contents awaiting import", to: existing.url)
        let digest = try hash(existing.url)
        var updated = try fetch(existing.id)
        updated.tagData = Data("new Finder tags".utf8)
        updated.isPinned = true
        updated.localPath = tempRoot.appendingPathComponent("Finder destination.txt").path
        let concurrentRow = updated
        let writer = try Database(path: database.filePath)
        let boundary = ReconciliationBoundary()
        let rootPath = storeRoot.path
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.attributes = { url in
            if url.path == rootPath {
                // Root lookups: initial check, scan, scan validation, then the
                // validation after the importer has captured its expected rows.
                if boundary.nextInvocation() == 4 {
                    boundary.arm()
                    try boundary.runOnce { try writer.saveItems([concurrentRow]) }
                }
            }
            return try live.attributes(url)
        }
        _ = try reconcile(files: files)
        XCTAssertTrue(boundary.fired)
        XCTAssertEqual(try fetch(existing.id), concurrentRow)
        XCTAssertEqual(try hash(existing.url), digest)
        XCTAssertEqual(PersonalFileStore.itemID(at: existing.url), existing.id)
    }

    func testGuardedLocalDeletionRemovesOnlyUnchangedCandidateLeaves() throws {
        let parent = LocalItem(id: "local-parent", siteID: siteID, courseID: 7, remoteID: 0, filename: "Parent", isDirectory: true, isLocal: true)
        let child = LocalItem(id: "local-child", parentID: parent.id, siteID: siteID, courseID: 7, remoteID: 0, filename: "Child", isLocal: true)
        try database.saveItems([parent, child])
        // Parent deliberately comes first: the API must delete bottom-up.
        XCTAssertEqual(try database.deleteLocalItemsIfUnchanged([parent, child]), 2)
        XCTAssertNil(try database.fetchItem(id: parent.id))
        XCTAssertNil(try database.fetchItem(id: child.id))
        XCTAssertEqual(Set(try database.fetchPendingDeletions()), Set([parent.id, child.id]))
    }

    func testEmptyAnchorCleanupCannotRemoveNewlyArrivingFile() throws {
        let directory = try makeStore().anchorDirectory(chain: [courseAnchor], siteID: siteID, siteName: siteName)
        let arriving = directory.appendingPathComponent("arriving.txt")
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.removeEmptyDirectory = { url in
            try Data("do not remove".utf8).write(to: url.appendingPathComponent("arriving.txt"))
            try live.removeEmptyDirectory(url)
        }
        let store = PersonalFileStore(rootURL: storeRoot, files: files)
        try store.removeEmptyAnchorDirectories(siteID: siteID)
        XCTAssertEqual(try String(contentsOf: arriving, encoding: .utf8), "do not remove")
        let marker = try JSONDecoder().decode(PersonalFileStore.Anchor.self, from: Data(contentsOf: directory.appendingPathComponent(".findle-anchor.json")))
        XCTAssertEqual(marker, courseAnchor)
    }

    func testClashRenameInterruptionRetainsContentsAndStableIdentity() throws {
        let file = try trackedFile()
        let digest = try hash(file.url)
        try database.saveItems([LocalItem(id: "remote-file", parentID: courseAnchor.itemID, siteID: siteID,
            courseID: 7, remoteID: 100, filename: "notes.txt")])
        let live = PersonalFileStore.FileOperations()
        var files = live
        files.move = { source, target in
            try live.move(source, target)
            throw POSIXError(.EIO)
        }
        _ = try reconcile(files: files)
        _ = try reconcile()
        let destination = URL(fileURLWithPath: try XCTUnwrap(fetch(file.id).localPath))
        XCTAssertEqual(destination.lastPathComponent, "notes (mine).txt")
        XCTAssertEqual(try hash(destination), digest)
        XCTAssertEqual(PersonalFileStore.itemID(at: destination), file.id)
    }

    func testUnsubscribeResubscribeAndDatabaseReplacementPreserveFileHashesAndIDs() throws {
        let file = try trackedFile()
        let digest = try hash(file.url)
        for enabled in [false, true] {
            try saveCourse(id: 7, enabled: enabled)
            try database.deleteItemsWithTombstone(ids: [courseAnchor.itemID])
            _ = try reconcile()
            XCTAssertEqual(try hash(file.url), digest)
            XCTAssertEqual(PersonalFileStore.itemID(at: file.url), file.id)
            XCTAssertNotNil(try database.fetchItem(id: file.id))
        }
        // Reconnect, logout, and provider-reset flows may replace cached rows.
        // A fresh database models that cache loss without using a signed domain.
        for index in 0..<3 {
            database = try Database(path: tempRoot.appendingPathComponent("replacement-\(index).db").path)
            _ = try reconcile()
            XCTAssertEqual(try hash(file.url), digest)
            XCTAssertEqual(PersonalFileStore.itemID(at: file.url), file.id)
            XCTAssertEqual(try fetch(file.id).parentID, courseAnchor.itemID)
        }
    }

    // MARK: - Name clashes

    func testMineFilenameKeepsExtensionWhenUsable() {
        XCTAssertEqual(PersonalFileStore.mineFilename(for: "notes.pdf"), "notes (mine).pdf")
        XCTAssertEqual(PersonalFileStore.mineFilename(for: "archive.tar.gz"), "archive.tar (mine).gz")
        XCTAssertEqual(PersonalFileStore.mineFilename(for: "README"), "README (mine)")
        XCTAssertEqual(PersonalFileStore.mineFilename(for: "Lecture 1.5 notes"), "Lecture 1.5 notes (mine)")
        XCTAssertEqual(PersonalFileStore.mineFilename(for: ".hidden"), ".hidden (mine)")
    }

    func testMoodleItemClashRenamesUserFileAndKeepsItsID() throws {
        try saveCourse(id: 7)
        let sectionDirectory = try makeStore().anchorDirectory(
            chain: [courseAnchor, sectionAnchor], siteID: siteID, siteName: siteName
        )
        let file = sectionDirectory.appendingPathComponent("notes.pdf")
        try writeFile("mine", to: file)
        XCTAssertTrue(try reconcile())
        let id = try XCTUnwrap(PersonalFileStore.itemID(at: file))

        try database.saveItems([
            LocalItem(id: "file-site-1-7-100", parentID: sectionAnchor.itemID, siteID: siteID, courseID: 7,
                      remoteID: 100, filename: "Notes.PDF", isDirectory: false, syncState: .materialized),
        ])

        XCTAssertTrue(try reconcile())

        let renamed = sectionDirectory.appendingPathComponent("notes (mine).pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertEqual(PersonalFileStore.itemID(at: renamed), id)
        let row = try fetch(id)
        XCTAssertEqual(row.filename, "notes (mine).pdf")
        XCTAssertEqual(canonical(URL(fileURLWithPath: try XCTUnwrap(row.localPath))), canonical(renamed))
        XCTAssertFalse(try reconcile(), "A clash that is already resolved changes nothing")
    }

    func testClashAvoidsExistingMineNameWithNumber() throws {
        try saveCourse(id: 7)
        let sectionDirectory = try makeStore().anchorDirectory(
            chain: [courseAnchor, sectionAnchor], siteID: siteID, siteName: siteName
        )
        try writeFile("mine", to: sectionDirectory.appendingPathComponent("notes.pdf"))
        try writeFile("other", to: sectionDirectory.appendingPathComponent("notes (mine).pdf"))
        XCTAssertTrue(try reconcile())
        try database.saveItems([
            LocalItem(id: "file-site-1-7-101", parentID: sectionAnchor.itemID, siteID: siteID, courseID: 7,
                      remoteID: 101, filename: "Notes.PDF", isDirectory: false, syncState: .materialized),
        ])

        XCTAssertTrue(try reconcile())

        XCTAssertTrue(FileManager.default.fileExists(atPath: sectionDirectory.appendingPathComponent("notes (mine) 2.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sectionDirectory.appendingPathComponent("notes.pdf").path))
        XCTAssertEqual(try String(contentsOf: sectionDirectory.appendingPathComponent("notes (mine).pdf"), encoding: .utf8), "other")
    }
}

/// Test coordination is synchronous and every mutable field is protected by the
/// lock; filesystem callbacks can execute on whichever thread runs reconciliation.
private final class ReconciliationBoundary: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    private var didFire = false
    private var invocations = 0

    var fired: Bool { lock.withLock { didFire } }

    func arm() { lock.withLock { armed = true } }

    func nextInvocation() -> Int {
        lock.withLock {
            invocations += 1
            return invocations
        }
    }

    func runOnce(_ operation: () throws -> Void) rethrows {
        let shouldRun = lock.withLock {
            guard armed, !didFire else { return false }
            didFire = true
            return true
        }
        if shouldRun { try operation() }
    }
}
