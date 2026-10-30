import XCTest
import Synchronization
@testable import FindleNetworking
import SharedDomain

final class AuthenticatedRequestSecurityTests: XCTestCase {
    private let site = MoodleSite(id: "trusted", displayName: "Trusted", baseURL: URL(string: "https://moodle.test/campus")!)

    override func tearDown() {
        SecurityURLProtocol.reset()
        super.tearDown()
    }

    private func client() -> MoodleClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SecurityURLProtocol.self]
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return MoodleClient(session: session)
    }

    func testAuthenticatedRequestsRequireSelectedHTTPSOriginIncludingPort() throws {
        let client = client()
        let token = AuthToken(token: "secret")
        for address in ["https://other.test/file", "http://moodle.test/file", "https://moodle.test:444/file",
                        "https://moodle.test.attacker.test/file", "https://user@moodle.test/file",
                        "https://user:password@moodle.test/file", "file:///tmp/file",
                        "https://moodle.test/file?TOKEN=secret", "https://moodle.test/file?%77stoken=secret",
                        "https://moodle.test/file?privatetoken=secret"] {
            XCTAssertThrowsError(try client.authenticatedFileRequest(fileURL: URL(string: address)!, site: site, token: token))
        }
        for address in ["https://MOODLE.test/file", "https://moodle.test:443/other-path?download=1"] {
            XCTAssertNoThrow(try client.authenticatedFileRequest(fileURL: URL(string: address)!, site: site, token: token))
        }
        let customPortSite = MoodleSite(displayName: "Custom", baseURL: URL(string: "https://moodle.test:8443")!)
        XCTAssertNoThrow(try client.authenticatedFileRequest(fileURL: URL(string: "https://moodle.test:8443/file")!, site: customPortSite, token: token))
        XCTAssertThrowsError(try client.authenticatedFileRequest(fileURL: URL(string: "https://moodle.test/file")!, site: customPortSite, token: token))
        XCTAssertTrue(SecurityURLProtocol.requests.isEmpty)
    }

    func testCapabilityAliasesDoNotAuthorizeAnotherOrigin() throws {
        let aliasSite = MoodleSite(displayName: "Selected", baseURL: site.baseURL,
                                  capabilities: SiteCapabilities(wwwroot: "https://other.test", httpswwwroot: "https://cdn.test"))
        for host in ["other.test", "cdn.test"] {
            XCTAssertThrowsError(try client().authenticatedFileRequest(fileURL: URL(string: "https://\(host)/file")!,
                                                                        site: aliasSite, token: AuthToken(token: "secret")))
        }
    }

    func testUntrustedDownloadFailsBeforeStartingTransportAndPreservesExistingFile() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try Data("existing".utf8).write(to: destination)
        do {
            try await client().downloadFile(url: URL(string: "https://external.test/file")!, site: site,
                                            token: AuthToken(token: "secret"), destination: destination)
            XCTFail("Untrusted download was accepted")
        } catch { XCTAssertTrue(error is AuthenticatedRequestError) }
        XCTAssertTrue(SecurityURLProtocol.requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
    }

    func testRedirectDelegateRejectsCredentialForwardingForEveryRedirectStatus() async throws {
        let delegate = AuthenticatedRedirectDelegate(origin: try AuthenticatedRequestOrigin(site: site))
        let original = try client().authenticatedFileRequest(fileURL: site.baseURL.appendingPathComponent("file"),
                                                            site: site, token: AuthToken(token: "sentinel-secret"))
        let task = URLSession.shared.dataTask(with: original) // Never resumed.
        defer { task.cancel() }
        for status in [301, 302, 303, 307, 308] {
            let response = HTTPURLResponse(url: original.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            for address in ["https://external.test/file", "http://moodle.test/file", "https://moodle.test:444/file",
                            "https://user@moodle.test/file", "https://moodle.test/file?token=sentinel-secret"] {
                var redirect = original
                redirect.url = URL(string: address)
                let accepted = await withCheckedContinuation { continuation in
                    delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                                        newRequest: redirect) { continuation.resume(returning: $0) }
                }
                XCTAssertNil(accepted, "Unsafe redirect accepted (\(status))")
            }
            var sameOrigin = original
            sameOrigin.url = URL(string: "https://moodle.test:443/redirected")
            let accepted = await withCheckedContinuation { continuation in
                delegate.urlSession(.shared, task: task, willPerformHTTPRedirection: response,
                                    newRequest: sameOrigin) { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(accepted?.url, sameOrigin.url)
            XCTAssertEqual(accepted?.httpBody, original.httpBody)
            XCTAssertEqual(accepted?.httpMethod, original.httpMethod)
        }
    }

    func testRealSessionDoesNotForwardPasswordOrAPITokenAcrossOriginOrDowngrade() async throws {
        for status in [307, 308] {
            for target in ["https://external.test/capture", "http://moodle.test/capture", "https://moodle.test:444/capture"] {
                SecurityURLProtocol.reset()
                SecurityURLProtocol.redirect(from: site.tokenURL, to: URL(string: target)!, status: status)
                do {
                    _ = try await client().authenticate(site: site, username: "fixture-user", password: "fixture-password")
                    XCTFail("Cross-origin sign-in redirect succeeded")
                } catch { XCTAssertTrue(error is AuthenticatedRequestError) }
                XCTAssertEqual(SecurityURLProtocol.requests.map(\.url), [site.tokenURL])

                SecurityURLProtocol.reset()
                SecurityURLProtocol.redirect(from: site.webServiceURL, to: URL(string: target)!, status: status)
                do {
                    _ = try await client().fetchCourses(site: site, token: AuthToken(token: "fixture-token"), userID: 1)
                    XCTFail("Cross-origin API redirect succeeded")
                } catch { XCTAssertTrue(error is AuthenticatedRequestError) }
                XCTAssertEqual(SecurityURLProtocol.requests.map(\.url), [site.webServiceURL])
            }
        }
    }

    func testRealSessionPreservesSameOriginPasswordAndAPIRedirects() async throws {
        let target = URL(string: "https://moodle.test/redirected")!
        for status in [307, 308] {
            SecurityURLProtocol.reset()
            SecurityURLProtocol.redirect(from: site.tokenURL, to: target, status: status, followed: true)
            SecurityURLProtocol.respond(at: target, data: Data(#"{"token":"returned-token"}"#.utf8))
            let token = try await client().authenticate(site: site, username: "fixture-user", password: "fixture-password")
            XCTAssertEqual(token.token, "returned-token")
            XCTAssertEqual(SecurityURLProtocol.requests.map(\.url), [site.tokenURL, target])
            XCTAssertEqual(SecurityURLProtocol.requests.last?.httpMethod, "POST")

            SecurityURLProtocol.reset()
            SecurityURLProtocol.redirect(from: site.webServiceURL, to: target, status: status, followed: true)
            SecurityURLProtocol.respond(at: target, data: Data("[]".utf8))
            let courses = try await client().fetchCourses(site: site, token: token, userID: 1)
            XCTAssertTrue(courses.isEmpty)
            XCTAssertEqual(SecurityURLProtocol.requests.map(\.url), [site.webServiceURL, target])
        }
    }

    func testInsecureSiteNeverStartsPasswordOrTokenTransport() async throws {
        let insecure = MoodleSite(displayName: "Insecure", baseURL: URL(string: "http://moodle.test")!)
        do {
            _ = try await client().authenticate(site: insecure, username: "fixture", password: "secret")
            XCTFail("Password was allowed over HTTP")
        } catch { XCTAssertTrue(error is AuthenticatedRequestError) }
        do {
            _ = try await client().fetchCourses(site: insecure, token: AuthToken(token: "secret"), userID: 1)
            XCTFail("Token was allowed over HTTP")
        } catch { XCTAssertTrue(error is AuthenticatedRequestError) }
        XCTAssertTrue(SecurityURLProtocol.requests.isEmpty)
    }

    func testMoodleInvalidCredentialsClassificationIsPreservedForHTTP401() async throws {
        SecurityURLProtocol.respond(at: site.tokenURL,
            data: Data(#"{"error":"Invalid login","errorcode":"invalidlogin"}"#.utf8), status: 401)
        do {
            _ = try await client().authenticate(site: site, username: "fixture", password: "wrong")
            XCTFail("Invalid credentials accepted")
        } catch FindleError.invalidCredentials {
            XCTAssertEqual(SecurityURLProtocol.requests.count, 1)
        } catch { XCTFail("Lost Moodle authentication classification: \(error)") }
    }

    func testAsyncFileDownloadsEnforceRedirectsAndKeepExistingDestinationOnFailure() async throws {
        let initial = URL(string: "https://moodle.test/file")!
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        for status in [307, 308] {
            for address in ["https://external.test/file", "http://moodle.test/file", "https://moodle.test:444/file"] {
                SecurityURLProtocol.reset()
                SecurityURLProtocol.redirect(from: initial, to: URL(string: address)!, status: status)
                try Data("existing".utf8).write(to: destination)
                do {
                    try await client().downloadFile(url: initial, site: site, token: AuthToken(token: "fixture-token"), destination: destination)
                    XCTFail("Unsafe download redirect succeeded")
                } catch { XCTAssertTrue(error is AuthenticatedRequestError) }
                XCTAssertEqual(SecurityURLProtocol.requests.map(\.url), [initial])
                XCTAssertEqual(try Data(contentsOf: destination), Data("existing".utf8))
            }
            SecurityURLProtocol.reset()
            let target = URL(string: "https://moodle.test/download")!
            SecurityURLProtocol.redirect(from: initial, to: target, status: status, followed: true)
            SecurityURLProtocol.respond(at: target, data: Data("downloaded".utf8))
            try await client().downloadFile(url: initial, site: site, token: AuthToken(token: "fixture-token"), destination: destination)
            XCTAssertEqual(SecurityURLProtocol.requests.map(\.url), [initial, target])
            XCTAssertEqual(try Data(contentsOf: destination), Data("downloaded".utf8))
        }
    }
}

/// Exercises URLSession's real task delegate dispatch with entirely local,
/// synthetic responses. No TLS exceptions, live endpoints, or credentials.
private final class SecurityURLProtocol: URLProtocol {
    private enum Reply: Sendable { case redirect(URL, Int, followed: Bool), data(Data, Int) }
    private struct State { var replies: [URL: Reply] = [:]; var requests: [URLRequest] = [] }
    private static let state = Mutex(State())
    static var requests: [URLRequest] { state.withLock { $0.requests } }
    static func reset() { state.withLock { $0 = State() } }
    /// `followed` states whether the test expects the client to accept the redirect.
    /// An accepted redirect must not also deliver the redirect response, or that
    /// response can race the followed request and complete the task with a 3xx.
    static func redirect(from: URL, to: URL, status: Int, followed: Bool = false) {
        state.withLock { $0.replies[from] = .redirect(to, status, followed: followed) }
    }
    static func respond(at url: URL, data: Data, status: Int = 200) { state.withLock { $0.replies[url] = .data(data, status) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.withLock { state -> Reply? in
            state.requests.append(request)
            return request.url.flatMap { state.replies[$0] }
        }
        guard let url = request.url else { return }
        switch reply {
        case let .redirect(destination, status, followed):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString])!
            var redirected = request
            redirected.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            // URLSession stops this protocol and loads the destination when the
            // redirect is accepted, as a real HTTP loader would.
            guard !followed else { return }
            // A refused redirect leaves the original response active. Finish
            // that response too; otherwise the fixture creates a fake timeout.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case let .data(data, status):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(data.count)])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
        }
    }
    override func stopLoading() {}
}
