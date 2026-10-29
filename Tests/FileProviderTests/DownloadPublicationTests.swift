import XCTest
import FileProvider
import SharedDomain
import FindlePersistence

final class DownloadPublicationTests: XCTestCase {
    private func fixture() throws -> ProviderFixture {
        let f = try ProviderFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: f.directory) }
        return f
    }

    private func response(_ status: Int = 200, size: Int64, type: String = "application/pdf") -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://moodle.test/file")!, statusCode: status,
                        httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(size), "Content-Type": type])!
    }

    func testZeroByteAndLargeSparseFilesPublishWithoutReadingIntoMemory() throws {
        let f = try fixture()
        for size in [Int64(0), Int64(5) * 1024 * 1024 * 1024] {
            var item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
            item.fileSize = size
            try f.database.saveItems([item])
            let source = f.directory.appendingPathComponent(UUID().uuidString)
            XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: UInt64(size))
            try handle.close()
            let destination = DownloadPublication.destination(for: item, in: f.directory)
            let updated = try DownloadPublication.publish(item: item, database: f.database, response: response(size: size),
                source: source, destination: destination, progress: Progress(totalUnitCount: 100))
            XCTAssertEqual(updated.syncState, .materialized)
            XCTAssertEqual(updated.localPath, destination.path)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value, size)
        }
    }

    func testRejectsPartialTruncatedAndUnexpectedHTMLWithoutFalseSignOut() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        let source = f.directory.appendingPathComponent("response")
        try Data("abc".utf8).write(to: source)
        for response in [response(206, size: 3), response(size: 4), response(size: 3, type: "text/html")] {
            assertProviderError(.serverUnreachable) {
                try DownloadPublication.validate(item: item, response: response, file: source, cancelled: false)
            }
        }
        assertProviderError(.notAuthenticated) {
            try DownloadPublication.validate(item: item, response: response(401, size: 3), file: source, cancelled: false)
        }
        do {
            try DownloadPublication.validate(item: item, response: response(403, size: 3), file: source, cancelled: false)
            XCTFail("Expected permission failure")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission) }
        try Data("ab".utf8).write(to: source)
        assertProviderError(.serverUnreachable) {
            try DownloadPublication.validate(item: item, response: response(size: 2), file: source, cancelled: false)
        }
        XCTAssertEqual(try f.database.fetchItem(id: item.id)?.syncState, .downloading)
    }

    func testActualHTMLFileIsAccepted() throws {
        let f = try fixture()
        var item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        item.contentType = "text/html"
        let source = f.directory.appendingPathComponent("response")
        try Data("abc".utf8).write(to: source)
        XCTAssertNoThrow(try DownloadPublication.validate(item: item, response: response(size: 3, type: "text/html"), file: source, cancelled: false))
    }

    func testStaleCompletionDoesNotOverwriteNewVersionAndRemovesStagedFile() throws {
        let f = try fixture()
        let old = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        var current = old
        current.contentVersion = "v2"
        current.syncState = .placeholder
        try f.database.saveItems([current])
        let source = f.directory.appendingPathComponent("response")
        try Data("abc".utf8).write(to: source)
        let destination = DownloadPublication.destination(for: old, in: f.directory)
        assertProviderError(.versionNoLongerAvailable) {
            _ = try DownloadPublication.publish(item: old, database: f.database, response: response(size: 3),
                source: source, destination: destination, progress: Progress(totalUnitCount: 100))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try f.database.fetchItem(id: old.id)?.contentVersion, "v2")
        XCTAssertEqual(try f.database.fetchItem(id: old.id)?.syncState, .placeholder)
        XCTAssertNil(try f.database.updateDownloadState(for: old, state: .placeholder, onlyIfDownloading: true))
    }

    func testCancellationBeforeAndAfterStagingDoesNotPublish() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        for cancelBefore in [true, false] {
            let source = f.directory.appendingPathComponent(UUID().uuidString)
            try Data("abc".utf8).write(to: source)
            let destination = DownloadPublication.destination(for: item, in: f.directory)
            let progress = Progress(totalUnitCount: 100)
            if cancelBefore { progress.cancel() }
            do {
                _ = try DownloadPublication.publish(item: item, database: f.database, response: response(size: 3),
                    source: source, destination: destination, progress: progress, move: {
                        try FileManager.default.moveItem(at: $0, to: $1)
                        progress.cancel()
                    })
                XCTFail("Cancelled request published content")
            } catch { XCTAssertEqual((error as? CocoaError)?.code, .userCancelled) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try f.database.fetchItem(id: item.id)?.syncState, .downloading)
        }
    }

    func testDiskFullLeavesSourceIntactAndRetryCanSucceed() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        let source = f.directory.appendingPathComponent("response")
        try Data("abc".utf8).write(to: source)
        let destination = DownloadPublication.destination(for: item, in: f.directory)
        do {
            _ = try DownloadPublication.publish(item: item, database: f.database, response: response(size: 3),
                source: source, destination: destination, progress: Progress(totalUnitCount: 100),
                move: { _, target in
                    try Data("partial".utf8).write(to: target)
                    throw CocoaError(.fileWriteOutOfSpace)
                })
            XCTFail("Expected disk-full error")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace) }
        XCTAssertEqual(try Data(contentsOf: source), Data("abc".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let updated = try DownloadPublication.publish(item: item, database: f.database, response: response(size: 3),
            source: source, destination: destination, progress: Progress(totalUnitCount: 100))
        XCTAssertEqual(updated.syncState, .materialized)
        // A later failed request of the same version cannot reset this success.
        XCTAssertNil(try f.database.updateDownloadState(for: item, state: .placeholder, onlyIfDownloading: true))
        XCTAssertEqual(try f.database.fetchItem(id: item.id)?.syncState, .materialized)
    }

    func testConcurrentRequestsUseDifferentStagingPaths() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        XCTAssertNotEqual(DownloadPublication.destination(for: item, in: f.directory),
                          DownloadPublication.destination(for: item, in: f.directory))
    }
}
