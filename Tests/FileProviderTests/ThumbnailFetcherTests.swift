import XCTest
import Synchronization
import FileProvider
import ImageIO
import UniformTypeIdentifiers
import SharedDomain
import FindlePersistence

final class ThumbnailFetcherTests: XCTestCase {
    private func item(_ id: String, type: String?, directory: Bool = false, personal: Bool = false,
                      url: String? = "https://moodle.test/webservice/pluginfile.php/1/mod_resource/content/1/a?forcedownload=1") -> LocalItem {
        LocalItem(id: id, parentID: "course-a-1", siteID: "a", courseID: 1, remoteID: 2, filename: id,
                  isDirectory: directory, contentType: type, remoteURL: url.flatMap(URL.init(string:)), isLocal: personal)
    }

    func testOnlyImagesAndCourseImagesHaveAThumbnail() throws {
        let cover = URL(string: "https://moodle.test/webservice/pluginfile.php/9/course/overviewfiles/cover.jpg")!
        let photo = try XCTUnwrap(ThumbnailFetcher.source(for: item("photo", type: "image/png"), courseImage: nil))
        XCTAssertEqual(URLComponents(url: photo, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "preview", value: "bigthumb")], "Moodle's preview replaces the forced download")
        XCTAssertEqual(ThumbnailFetcher.source(for: item("course-a-1", type: nil, directory: true), courseImage: cover)?.absoluteString,
                       cover.absoluteString + "?preview=bigthumb")

        XCTAssertNil(ThumbnailFetcher.source(for: item("notes", type: "application/pdf"), courseImage: cover),
                     "Moodle would send a generic icon for a PDF")
        XCTAssertNil(ThumbnailFetcher.source(for: item("vector", type: "image/svg+xml"), courseImage: nil))
        XCTAssertNil(ThumbnailFetcher.source(for: item("mine", type: "image/png", personal: true), courseImage: nil))
        XCTAssertNil(ThumbnailFetcher.source(for: item("photo", type: "image/png", url: nil), courseImage: nil))
        XCTAssertNil(ThumbnailFetcher.source(for: item("course-a-1", type: nil, directory: true), courseImage: nil))
        XCTAssertNil(ThumbnailFetcher.source(for: item("section-a-1-2", type: nil, directory: true), courseImage: cover))
    }

    func testEachItemGetsItsImageOrNothingThenTheRequestEndsOnce() throws {
        let f = try ProviderFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: f.directory) }
        try f.database.saveCourses([MoodleCourse(id: 1, shortName: "C", fullName: "Course", siteID: "a",
                                                 imageURL: URL(string: "https://moodle.test/cover.jpg"))])
        try f.database.saveItems([
            item("course-a-1", type: nil, directory: true),
            item("photo-a", type: "image/png", url: "https://moodle.test/photo.png"),
            item("broken-a", type: "image/jpeg", url: "https://moodle.test/error.jpg")
        ])
        ThumbnailURLProtocol.reset()
        let fetcher = makeFetcher()
        defer { fetcher.invalidate() }

        let results = Mutex<[String: Data?]>([:])
        let finished = expectation(description: "request finished")
        let identifiers = ["course-a-1", "photo-a", "broken-a", "file-a", "missing"].map { NSFileProviderItemIdentifier($0) }
        _ = fetcher.fetchThumbnails(
            for: identifiers, database: f.database, siteID: "a", tokenReader: { _ in "fixture-secret" },
            perThumbnail: { identifier, data, error in
                XCTAssertNil(error)
                results.withLock { $0[identifier.rawValue] = data }
            },
            completion: { error in
                XCTAssertNil(error)
                XCTAssertEqual(results.withLock { $0.count }, identifiers.count, "Every thumbnail is reported before the end")
                finished.fulfill()
            })
        wait(for: [finished], timeout: 5)

        let delivered = results.withLock { $0 }
        XCTAssertEqual(delivered["course-a-1"] ?? nil, Self.png)
        XCTAssertEqual(delivered["photo-a"] ?? nil, Self.png)
        XCTAssertEqual(delivered["broken-a"] ?? Data(), nil, "An error page is not a thumbnail")
        XCTAssertEqual(delivered["file-a"] ?? Data(), nil, "A PDF keeps Finder's icon")
        XCTAssertEqual(delivered["missing"] ?? Data(), nil)
        let requests = ThumbnailURLProtocol.requests
        XCTAssertEqual(Set(requests.map(\.url)), ["https://moodle.test/cover.jpg?preview=bigthumb",
                                                 "https://moodle.test/photo.png?preview=bigthumb",
                                                 "https://moodle.test/error.jpg?preview=bigthumb"])
        XCTAssertTrue(requests.allSatisfy { $0.body == "token=fixture-secret" && !$0.url.contains("secret") })
    }

    func testWithoutASignInNothingIsRequested() throws {
        let f = try ProviderFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: f.directory) }
        try f.database.saveItems([item("photo-a", type: "image/png", url: "https://moodle.test/photo.png")])
        ThumbnailURLProtocol.reset()
        let fetcher = makeFetcher()
        defer { fetcher.invalidate() }
        let finished = expectation(description: "request finished")
        _ = fetcher.fetchThumbnails(
            for: [NSFileProviderItemIdentifier("photo-a")], database: f.database, siteID: "a", tokenReader: { _ in nil },
            perThumbnail: { _, data, error in XCTAssertNil(data); XCTAssertNil(error) },
            completion: { _ in finished.fulfill() })
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(ThumbnailURLProtocol.requests.isEmpty)
    }

    private func makeFetcher() -> ThumbnailFetcher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ThumbnailURLProtocol.self]
        return ThumbnailFetcher(configuration: configuration)
    }

    static let png: Data = {
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()
}

private final class ThumbnailURLProtocol: URLProtocol {
    struct Request: Sendable { let url: String; let body: String }
    private static let recorded = Mutex<[Request]>([])
    static var requests: [Request] { recorded.withLock { $0 } }
    static func reset() { recorded.withLock { $0 = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.recorded.withLock { $0.append(Request(url: url.absoluteString, body: Self.body(of: request))) }
        let body = url.path.contains("error") ? Data(#"<html>Sorry, the requested file could not be found</html>"#.utf8)
                                              : ThumbnailFetcherTests.png
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private static func body(of request: URLRequest) -> String {
        if let body = request.httpBody { return String(decoding: body, as: UTF8.self) }
        guard let stream = request.httpBodyStream else { return "" }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
