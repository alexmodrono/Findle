import XCTest
import FileProvider
import SharedDomain
import FindlePersistence

final class DownloadRetentionTests: XCTestCase {
    private var directory: URL!
    private var database: Database!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("retention-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try Database(path: directory.appendingPathComponent("findle.db").path)
        func file(_ id: String, parent: String, state: ItemSyncState) -> LocalItem {
            LocalItem(id: id, parentID: parent, siteID: "a", courseID: 1, remoteID: 2, filename: id + ".pdf",
                      contentType: "application/pdf", fileSize: 3, syncState: state,
                      remoteURL: URL(string: "https://moodle.test/" + id), contentVersion: "v1")
        }
        try database.saveItems([
            LocalItem(id: "course", siteID: "a", courseID: 1, remoteID: 1, filename: "Course", isDirectory: true),
            file("slides", parent: "course", state: .materialized),
            file("notes", parent: "course", state: .placeholder),
            LocalItem(id: "week", parentID: "course", siteID: "a", courseID: 1, remoteID: 3, filename: "Week 1", isDirectory: true),
            file("lab", parent: "week", state: .materialized),
            LocalItem(id: "local-essay", parentID: "course", siteID: "a", courseID: 1, remoteID: 0,
                      filename: "Essay.pages", fileSize: 3, syncState: .materialized, isLocal: true)
        ])
    }

    override func tearDownWithError() throws {
        database = nil
        try FileManager.default.removeItem(at: directory)
    }

    func testContentPolicyAndMetadataFollowTheKeptState() throws {
        let item = try XCTUnwrap(database.fetchItem(id: "slides"))
        var kept = item
        kept.isPinned = true
        XCTAssertEqual(FileProviderItem(localItem: item).contentPolicy, .inherited)
        XCTAssertEqual(FileProviderItem(localItem: kept).contentPolicy, .downloadEagerlyAndKeepDownloaded)
        XCTAssertNotEqual(FileProviderItem(localItem: item).itemVersion.metadataVersion,
                          FileProviderItem(localItem: kept).itemVersion.metadataVersion,
                          "The system only re-reads the policy when the metadata version changes")
        XCTAssertEqual(FileProviderItem(localItem: item).itemVersion.contentVersion,
                       FileProviderItem(localItem: kept).itemVersion.contentVersion,
                       "Keeping a file must not look like new content")
    }

    func testKeepMarksTheWholeFolder() throws {
        try DownloadRetention.keep(["course"], database: database)
        for id in ["course", "slides", "notes", "week", "lab", "local-essay"] {
            XCTAssertEqual(try database.fetchItem(id: id)?.isPinned, true, id)
        }
    }

    func testRemoveUnpinsBeforeEvictingEachSyncedFile() async throws {
        try DownloadRetention.keep(["course"], database: database)
        let recorder = Recorder()
        try await DownloadRetention.remove(
            ["course"], database: database,
            signal: { recorder.record("signal") },
            evict: { id in
                XCTAssertEqual(try self.database.fetchItem(id: id)?.isPinned, false, "Evicting a kept file fails")
                recorder.record(id)
            },
            retryDelay: .zero
        )
        XCTAssertEqual(recorder.events.first, "signal")
        XCTAssertEqual(Set(recorder.events.dropFirst()), ["slides", "notes", "lab"],
                       "Folders are not evicted whole, and personal files are never evicted")
        XCTAssertEqual(try database.fetchItem(id: "slides")?.syncState, .placeholder)
        XCTAssertEqual(try database.fetchItem(id: "lab")?.syncState, .placeholder)
        XCTAssertEqual(try database.fetchItem(id: "local-essay")?.syncState, .materialized)
        XCTAssertEqual(try database.fetchItem(id: "local-essay")?.isPinned, false)
    }

    func testRemoveRetriesWhileTheSystemStillHoldsTheOldPolicy() async throws {
        let recorder = Recorder()
        try await DownloadRetention.remove(
            ["slides"], database: database, signal: {},
            evict: { id in
                recorder.record(id)
                if recorder.events.count < 3 { throw NSFileProviderError(.nonEvictable) }
            },
            retryDelay: .zero
        )
        XCTAssertEqual(recorder.events, ["slides", "slides", "slides"])
        XCTAssertEqual(try database.fetchItem(id: "slides")?.syncState, .placeholder)
    }

    func testRemoveContinuesPastAnOpenFileAndReportsIt() async throws {
        let recorder = Recorder()
        do {
            try await DownloadRetention.remove(
                ["course"], database: database, signal: {},
                evict: { id in
                    recorder.record(id)
                    if id == "slides" { throw POSIXError(.EBUSY) }
                },
                retryDelay: .zero
            )
            XCTFail("An open file must be reported")
        } catch {
            XCTAssertEqual((error as? POSIXError)?.code, .EBUSY)
        }
        XCTAssertEqual(Set(recorder.events), ["slides", "notes", "lab"], "An open file is not retried")
        XCTAssertEqual(recorder.events.filter { $0 == "slides" }.count, 1)
        XCTAssertEqual(try database.fetchItem(id: "slides")?.syncState, .materialized)
        XCTAssertEqual(try database.fetchItem(id: "lab")?.syncState, .placeholder)
    }

    func testRepublishingReportsEveryItemAsChangedWithoutChangingIt() throws {
        try database.updateItemPinned(id: "lab", isPinned: true)
        let before = try database.fetchItem(id: "lab")
        let anchor = try database.currentChangeCounter()
        XCTAssertEqual(try database.republishAllItems(), 6)
        XCTAssertEqual(Set(try database.fetchItemsChangedSince(anchor: anchor, siteID: "a").map(\.id)),
                       ["course", "slides", "notes", "week", "lab", "local-essay"])
        XCTAssertEqual(try database.fetchItem(id: "lab")?.isPinned, before?.isPinned)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func record(_ event: String) { lock.withLock { recorded.append(event) } }
}
