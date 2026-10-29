import XCTest
import Synchronization
import FileProvider
import SharedDomain
import FindleNetworking
import FindlePersistence

final class DownloadSecurityTests: XCTestCase {
    private func fixture() throws -> ProviderFixture {
        let fixture = try ProviderFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        return fixture
    }

    private func bookmark(url: String = "https://external.test/article?section=1&view=2") -> LocalItem {
        LocalItem(id: "url-a-1-3", parentID: "root-a", siteID: "a", courseID: 1, remoteID: 3,
                  filename: "Reading.webloc", contentType: "com.apple.web-internet-location",
                  fileSize: 999, remoteURL: URL(string: url), contentVersion: "v1")
    }

    func testURLResourcePublishesLocalBookmarkWithoutReadingCredentials() throws {
        let f = try fixture()
        let item = bookmark()
        try f.database.saveItems([item])
        let progress = Progress(totalUnitCount: 100)
        var completions = 0
        try FileDownloader.startDownload(item: item, database: f.database, progress: progress,
            temporaryDirectory: f.directory, tokenReader: { _ in
                XCTFail("A URL resource must not read Keychain")
                return "must-never-be-sent"
            }, completionHandler: { url, result, error in
                completions += 1
                XCTAssertNil(error)
                XCTAssertEqual(result?.itemIdentifier.rawValue, item.id)
                do {
                    let data = try Data(contentsOf: XCTUnwrap(url))
                    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
                    XCTAssertEqual(plist, ["URL": item.remoteURL!.absoluteString])
                    XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("must-never-be-sent"))
                } catch { XCTFail("Bookmark was not readable: \(error)") }
            })
        XCTAssertEqual(completions, 1)
        XCTAssertEqual(progress.fractionCompleted, 1)
        XCTAssertEqual(try f.database.fetchItem(id: item.id)?.syncState, .materialized)
    }

    func testUntrustedFilesAreRejectedBeforeCredentialsOrStateChanges() throws {
        let f = try fixture()
        let original = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        for destination in ["https://external.test/file", "http://moodle.test/file",
                            "https://moodle.test:444/file", "https://user:password@moodle.test/file",
                            "https://moodle.test/file?%74oken=secret", "https://moodle.test/file?wstoken=secret"] {
            var item = original
            item.remoteURL = URL(string: destination)
            try f.database.saveItems([item])
            XCTAssertThrowsError(try FileDownloader.startDownload(item: item, database: f.database,
                progress: Progress(totalUnitCount: 100), temporaryDirectory: f.directory,
                tokenReader: { _ in XCTFail("Untrusted URL reached Keychain"); return nil },
                completionHandler: { _, _, _ in XCTFail("Rejected request completed") }))
            XCTAssertEqual(try f.database.fetchItem(id: item.id), item)
        }
    }

    func testWeblocExtensionAloneDoesNotBypassOriginValidation() throws {
        let f = try fixture()
        // An uploaded file with a bookmark filename/type is still a remote file.
        let item = LocalItem(id: "file-a-1-3-Reading.webloc", siteID: "a", courseID: 1, remoteID: 3,
                             filename: "Reading.webloc", contentType: "com.apple.web-internet-location",
                             remoteURL: URL(string: "https://external.test/steal"))
        try f.database.saveItems([item])
        XCTAssertThrowsError(try FileDownloader.startDownload(item: item, database: f.database,
            progress: Progress(totalUnitCount: 100), temporaryDirectory: f.directory,
            tokenReader: { _ in XCTFail("Extension-based bypass reached Keychain"); return nil },
            completionHandler: { _, _, _ in XCTFail("Not a Moodle URL resource") }))
    }

    func testSiteReadFailureIsTransientAndDoesNotReadCredentials() throws {
        let f = try fixture()
        let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
        try providerSQL("UPDATE sites SET base_url = 'https://[invalid' WHERE id = 'a'", path: f.path)
        XCTAssertThrowsError(try f.database.fetchSite(id: item.siteID))
        assertProviderError(.serverUnreachable) {
            try FileDownloader.startDownload(item: item, database: f.database,
                progress: Progress(totalUnitCount: 100), temporaryDirectory: f.directory,
                tokenReader: { _ in XCTFail("Unreadable site reached Keychain"); return nil },
                completionHandler: { _, _, _ in XCTFail("Failed request completed") })
        }
        XCTAssertEqual(try f.database.fetchItem(id: item.id), item)
    }

    func testBookmarkDatabaseFailureIsTransientAndRemovesStagedFiles() throws {
        let f = try fixture()
        let item = bookmark()
        try f.database.saveItems([item])
        try providerSQL("""
            CREATE TRIGGER reject_bookmark_publication BEFORE UPDATE OF sync_state ON items
            WHEN NEW.sync_state = 'materialized'
            BEGIN SELECT RAISE(ABORT, 'fixture publication failure'); END;
            """, path: f.path)
        let staging = f.directory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        assertProviderError(.serverUnreachable) {
            try FileDownloader.startDownload(item: item, database: f.database,
                progress: Progress(totalUnitCount: 100), temporaryDirectory: staging,
                tokenReader: { _ in XCTFail("Bookmark read credentials"); return nil },
                completionHandler: { _, _, _ in XCTFail("Failed bookmark completed") })
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        XCTAssertEqual(try f.database.fetchItem(id: item.id), item)
    }

    func testCancelledOrReplacedBookmarksLeaveNoStagedFiles() throws {
        let f = try fixture()
        let item = bookmark()
        try f.database.saveItems([item])
        let before = try FileManager.default.contentsOfDirectory(atPath: f.directory.path)
        let progress = Progress(totalUnitCount: 100)
        progress.cancel()
        XCTAssertThrowsError(try FileDownloader.startDownload(item: item, database: f.database, progress: progress,
            temporaryDirectory: f.directory, tokenReader: { _ in XCTFail("Cancelled bookmark read credentials"); return nil },
            completionHandler: { _, _, _ in XCTFail("Cancelled request completed") })) {
                XCTAssertEqual(($0 as? CocoaError)?.code, .userCancelled)
            }
        var replaced = item
        replaced.contentVersion = "v2"
        try f.database.saveItems([replaced])
        XCTAssertThrowsError(try FileDownloader.startDownload(item: item, database: f.database,
            progress: Progress(totalUnitCount: 100), temporaryDirectory: f.directory,
            tokenReader: { _ in XCTFail("Stale bookmark read credentials"); return nil },
            completionHandler: { _, _, _ in XCTFail("Stale request completed") })) {
                XCTAssertEqual(($0 as? NSFileProviderError)?.code, .versionNoLongerAvailable)
            }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: f.directory.path)), Set(before))
        XCTAssertEqual(try f.database.fetchItem(id: item.id), replaced)
    }

    func testCancellationWhileStagingGeneratedBookmarkRemovesOwnedFiles() throws {
        let f = try fixture()
        let item = bookmark()
        try f.database.saveItems([item])
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: f.directory.path))
        let progress = Progress(totalUnitCount: 100)
        XCTAssertThrowsError(try DownloadPublication.publishGenerated(try XCTUnwrap(MoodleWebLocation.data(for: item)),
            item: item, database: f.database, destination: f.directory.appendingPathComponent("cancelled.webloc"),
            progress: progress, move: { source, destination in
                try FileManager.default.moveItem(at: source, to: destination)
                progress.cancel()
            }))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: f.directory.path)), before)
        XCTAssertEqual(try f.database.fetchItem(id: item.id), item)
    }

    func testCoordinatorEnforcesRedirectOriginAndPublishesOnlySameOriginBytes() async throws {
        for status in [307, 308] {
            for address in ["https://external.test/download", "http://moodle.test/download",
                            "https://moodle.test:444/download", "https://moodle.test/download"] {
                let f = try fixture()
                let item = try XCTUnwrap(f.database.fetchItem(id: "file-a"))
                let target = URL(string: address)!
                let allowed = address == "https://moodle.test/download"
                ProviderDownloadURLProtocol.configure(target: target, status: status)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ProviderDownloadURLProtocol.self]
                configuration.timeoutIntervalForRequest = 2
                configuration.timeoutIntervalForResource = 5
                let coordinator = DownloadCoordinator(configuration: configuration)
                let origin = try AuthenticatedRequestOrigin(site: XCTUnwrap(f.database.fetchSite(id: item.siteID)))
                let request = try origin.fileRequest(url: XCTUnwrap(item.remoteURL), token: AuthToken(token: "fixture-secret"))
                let destination = DownloadPublication.destination(for: item, in: f.directory)
                let progress = Progress(totalUnitCount: 100)
                let completed = expectation(description: "download \(status) \(address)")
                completed.assertForOverFulfill = true
                let bridge = FileDownloadCompletionBridge(progress: progress) { url, result, error in
                    if allowed {
                        XCTAssertNil(error)
                        XCTAssertEqual(url, destination)
                        XCTAssertEqual(result?.itemIdentifier.rawValue, item.id)
                    } else {
                        XCTAssertNotNil(error)
                        XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoPermission)
                        XCTAssertNil(url)
                        XCTAssertNil(result)
                    }
                    completed.fulfill()
                }
                coordinator.start(request: request, origin: origin, item: item, database: f.database,
                                  destination: destination, progress: progress, bridge: bridge)
                await fulfillment(of: [completed], timeout: 6)
                coordinator.invalidate()
                XCTAssertEqual(ProviderDownloadURLProtocol.urls, allowed ? [item.remoteURL!, target] : [item.remoteURL!])
                XCTAssertEqual(try f.database.fetchItem(id: item.id)?.syncState, allowed ? .materialized : .placeholder)
                if allowed {
                    XCTAssertEqual(try Data(contentsOf: destination), Data("abc".utf8))
                } else {
                    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
                }
            }
        }
    }
}

private final class ProviderDownloadURLProtocol: URLProtocol {
    private struct State {
        var target: URL?
        var status = 307
        var urls: [URL] = []
    }
    private static let state = Mutex(State())
    static var urls: [URL] { state.withLock { $0.urls } }
    static func configure(target: URL, status: Int) { state.withLock { $0 = State(target: target, status: status) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let (target, status) = Self.state.withLock { state in
            state.urls.append(url)
            return (state.target!, state.status)
        }
        if url.path == "/file" {
            var redirected = request
            redirected.url = target
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": target.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let data = Data("abc".utf8)
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/pdf", "Content-Length": "3"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
