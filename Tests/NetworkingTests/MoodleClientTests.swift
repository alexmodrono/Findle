import XCTest
@testable import FoodleNetworking
@testable import SharedDomain

final class MoodleClientTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeMockedClient(
        handler: @escaping MockURLProtocol.RequestHandler
    ) -> MoodleClient {
        MockURLProtocol.requestHandler = handler

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return MoodleClient(session: session)
    }

    private func makeHTTPResponse(
        url: URL,
        statusCode: Int = 200
    ) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
    }

    func testURLNormalization() {
        let url1 = MoodleClient.normalizeURL(URL(string: "https://moodle.example.edu/")!)
        XCTAssertEqual(url1.absoluteString, "https://moodle.example.edu")

        let url2 = MoodleClient.normalizeURL(URL(string: "https://moodle.example.edu///")!)
        XCTAssertEqual(url2.absoluteString, "https://moodle.example.edu")
    }

    func testAuthenticatedFileURL() {
        let client = MoodleClient()
        let token = AuthToken(token: "testtoken123")
        let fileURL = URL(string: "https://moodle.example.edu/pluginfile.php/123/mod_resource/content/1/file.pdf")!

        let result = client.authenticatedFileURL(fileURL: fileURL, token: token)

        XCTAssertTrue(result.absoluteString.contains("token=testtoken123"))
    }

    func testTokenResponseDecoding() throws {
        let json = """
        {"token": "abc123", "privatetoken": "xyz789"}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)

        XCTAssertEqual(response.token, "abc123")
        XCTAssertEqual(response.privatetoken, "xyz789")
        XCTAssertNil(response.error)
    }

    func testTokenResponseErrorDecoding() throws {
        let json = """
        {"error": "Invalid login", "errorcode": "invalidlogin", "stacktrace": null, "debuginfo": null, "reproductionlink": null}
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(TokenResponse.self, from: data)

        XCTAssertNil(response.token)
        XCTAssertEqual(response.error, "Invalid login")
        XCTAssertEqual(response.errorcode, "invalidlogin")
    }

    func testSiteInfoResponseDecoding() throws {
        let url = Bundle(for: type(of: self)).url(forResource: "mock_site_info_response", withExtension: "json", subdirectory: "Fixtures")
            ?? URL(fileURLWithPath: "Fixtures/mock_site_info_response.json")

        guard let data = try? Data(contentsOf: url) else {
            // Skip if fixture not available in test bundle
            return
        }

        let response = try JSONDecoder().decode(SiteInfoResponse.self, from: data)
        XCTAssertEqual(response.userid, 42)
        XCTAssertEqual(response.username, "jdoe")
        XCTAssertEqual(response.fullname, "Jane Doe")
    }

    func testCourseResponseDecoding() throws {
        let json = """
        [
          {
            "id": 101,
            "shortname": "CS101",
            "fullname": "Introduction to Computer Science",
            "summary": "<p>A course.</p>",
            "category": 5,
            "startdate": 1693526400,
            "enddate": 1701302400,
            "lastaccess": 1700000000,
            "visible": 1
          }
        ]
        """
        let data = json.data(using: .utf8)!
        let courses = try JSONDecoder().decode([CourseResponse].self, from: data)

        XCTAssertEqual(courses.count, 1)
        XCTAssertEqual(courses[0].id, 101)
        XCTAssertEqual(courses[0].shortname, "CS101")
    }

    func testValidateSiteUsesPublicConfigWithoutTokenProbe() async throws {
        let lock = NSLock()
        var requestedPaths: [String] = []
        let client = makeMockedClient { request in
            lock.lock()
            requestedPaths.append(request.url?.path ?? "")
            lock.unlock()

            guard let url = request.url else {
                throw URLError(.badURL)
            }

            if url.path == "/lib/ajax/service-nologin.php" {
                let json = """
                [
                  {
                    "data": {
                      "sitename": "Example Moodle",
                      "release": "4.3",
                      "version": "2024100100",
                      "typeoflogin": 2
                    }
                  }
                ]
                """
                return (self.makeHTTPResponse(url: url), Data(json.utf8))
            }

            XCTFail("Unexpected validation probe: \(url.path)")
            throw URLError(.unsupportedURL)
        }

        let site = try await client.validateSite(url: URL(string: "https://moodle.example.edu")!)

        XCTAssertEqual(site.displayName, "Example Moodle")
        XCTAssertEqual(site.capabilities.loginType, .browser)
        XCTAssertEqual(requestedPaths, ["/lib/ajax/service-nologin.php"])
    }

    func testValidateSiteFallsBackToTokenProbeWhenPublicConfigIsUnreadable() async throws {
        let lock = NSLock()
        var requestedPaths: [String] = []
        let client = makeMockedClient { request in
            lock.lock()
            requestedPaths.append(request.url?.path ?? "")
            lock.unlock()

            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch url.path {
            case "/lib/ajax/service-nologin.php":
                return (self.makeHTTPResponse(url: url), Data("<html>not moodle config</html>".utf8))
            case "/login/token.php":
                let json = """
                {"error":"Invalid login","errorcode":"invalidlogin"}
                """
                return (self.makeHTTPResponse(url: url), Data(json.utf8))
            default:
                XCTFail("Unexpected validation probe: \(url.path)")
                throw URLError(.unsupportedURL)
            }
        }

        let site = try await client.validateSite(url: URL(string: "https://moodle.example.edu")!)

        XCTAssertEqual(site.displayName, "moodle.example.edu")
        XCTAssertFalse(site.capabilities.supportsMobileAPI)
        XCTAssertEqual(
            requestedPaths,
            ["/lib/ajax/service-nologin.php", "/login/token.php"]
        )
    }

    func testValidateSiteSurfacesWebServicesDisabledFromCompatibilityProbe() async {
        let client = makeMockedClient { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }

            switch url.path {
            case "/lib/ajax/service-nologin.php":
                return (self.makeHTTPResponse(url: url), Data("<html>not moodle config</html>".utf8))
            case "/login/token.php":
                let json = """
                {"error":"Web services disabled","errorcode":"enablewsdescription"}
                """
                return (self.makeHTTPResponse(url: url), Data(json.utf8))
            default:
                throw URLError(.unsupportedURL)
            }
        }

        do {
            _ = try await client.validateSite(url: URL(string: "https://moodle.example.edu")!)
            XCTFail("Expected validation to fail")
        } catch let error as FoodleError {
            guard case .webServicesDisabled = error else {
                XCTFail("Expected webServicesDisabled, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testValidateSiteDoesNotRetryFastValidationFailures() async {
        let lock = NSLock()
        var requestCount = 0
        let client = makeMockedClient { request in
            lock.lock()
            requestCount += 1
            lock.unlock()

            _ = request
            throw URLError(.cannotFindHost)
        }

        do {
            _ = try await client.validateSite(url: URL(string: "https://missing.example.edu")!)
            XCTFail("Expected validation to fail")
        } catch let error as FoodleError {
            guard case .siteUnreachable = error else {
                XCTFail("Expected siteUnreachable, got \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(requestCount, 1)
    }

    // MARK: - SSO Token Parsing (MD5 Signature Validation)

    /// Helper to build a Moodle-format SSO callback URL string.
    /// Moodle encodes: base64(md5(siteURL + passport) + ":::" + token [+ ":::" + privateToken])
    private func buildCallback(
        scheme: String = "findle",
        siteURL: String,
        passport: String,
        token: String,
        privateToken: String? = nil,
        format: CallbackFormat = .hostEquals
    ) -> String {
        let signature = MoodleClient.md5("\(siteURL)\(passport)")
        var payload = "\(signature):::\(token)"
        if let pt = privateToken {
            payload += ":::\(pt)"
        }
        let base64 = Data(payload.utf8).base64EncodedString()

        switch format {
        case .hostEquals:
            return "\(scheme)://token=\(base64)"
        case .queryParam:
            return "\(scheme)://token?token=\(base64)"
        }
    }

    enum CallbackFormat {
        case hostEquals
        case queryParam
    }

    private func makeSite(
        baseURL: String = "https://sifo.comillas.edu",
        wwwroot: String? = nil,
        httpswwwroot: String? = nil
    ) -> MoodleSite {
        MoodleSite(
            displayName: "Test",
            baseURL: URL(string: baseURL)!,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true,
                loginType: .embedded,
                wwwroot: wwwroot,
                httpswwwroot: httpswwwroot
            )
        )
    }

    func testSSOTokenParsingWithMD5Signature() throws {
        let client = MoodleClient()
        let passport = "abc123passport"
        let token = "realtoken456"
        let privateToken = "privatetok789"
        let siteURL = "https://sifo.comillas.edu"

        let callbackString = buildCallback(
            siteURL: siteURL,
            passport: passport,
            token: token,
            privateToken: privateToken
        )
        let site = makeSite(baseURL: siteURL)

        let result = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackString,
            site: site,
            passport: passport
        )

        XCTAssertEqual(result.token, token)
        XCTAssertEqual(result.privateToken, privateToken)
    }

    func testSSOTokenParsingWithoutPrivateToken() throws {
        let client = MoodleClient()
        let passport = "mypassport"
        let token = "mytoken"
        let siteURL = "https://moodle.example.edu"

        let callbackString = buildCallback(siteURL: siteURL, passport: passport, token: token)
        let site = makeSite(baseURL: siteURL)

        let result = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackString,
            site: site,
            passport: passport
        )

        XCTAssertEqual(result.token, token)
        XCTAssertNil(result.privateToken)
    }

    func testSSOTokenParsingMatchesWwwroot() throws {
        let client = MoodleClient()
        let passport = "wp"
        let token = "tok"
        let wwwroot = "https://sifo.comillas.edu"
        // Signature is computed against wwwroot, not the baseURL.
        let callbackString = buildCallback(siteURL: wwwroot, passport: passport, token: token)

        let site = makeSite(
            baseURL: "https://sifo.comillas.edu",
            wwwroot: wwwroot
        )

        let result = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackString,
            site: site,
            passport: passport
        )
        XCTAssertEqual(result.token, token)
    }

    func testSSOTokenParsingMatchesHttpswwwroot() throws {
        let client = MoodleClient()
        let passport = "hp"
        let token = "tok"
        let httpswwwroot = "https://sifo.comillas.edu"
        let callbackString = buildCallback(siteURL: httpswwwroot, passport: passport, token: token)

        let site = makeSite(
            baseURL: "http://sifo.comillas.edu",
            httpswwwroot: httpswwwroot
        )

        let result = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackString,
            site: site,
            passport: passport
        )
        XCTAssertEqual(result.token, token)
    }

    func testSSOTokenParsingMatchesHTTPAlternate() throws {
        let client = MoodleClient()
        let passport = "altp"
        let token = "alttok"
        // Signature is computed against the HTTP alternate of an HTTPS base URL.
        let callbackString = buildCallback(
            siteURL: "http://moodle.example.edu",
            passport: passport,
            token: token
        )

        let site = makeSite(baseURL: "https://moodle.example.edu")

        let result = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackString,
            site: site,
            passport: passport
        )
        XCTAssertEqual(result.token, token)
    }

    func testSSOTokenParsingRejectsWrongSignature() {
        let client = MoodleClient()
        // Build a callback with a signature from a different site.
        let callbackString = buildCallback(
            siteURL: "https://wrong-site.edu",
            passport: "p",
            token: "t"
        )
        let site = makeSite(baseURL: "https://correct-site.edu")

        XCTAssertThrowsError(
            try client.parseTokenFromSSOCallback(callbackURLString: callbackString, site: site, passport: "p")
        ) { error in
            guard let foodleError = error as? FoodleError,
                  case .invalidResponse(let detail) = foodleError else {
                XCTFail("Expected invalidResponse error")
                return
            }
            XCTAssertTrue(detail.contains("security verification"))
        }
    }

    func testSSOTokenParsingRejectsRawPassportPayload() {
        let client = MoodleClient()
        // Old-format payload: rawpassport:::token (NOT md5)
        let payload = "rawpassport:::token123"
        let base64 = Data(payload.utf8).base64EncodedString()
        let callbackString = "findle://token=\(base64)"
        let site = makeSite(baseURL: "https://moodle.example.edu")

        XCTAssertThrowsError(
            try client.parseTokenFromSSOCallback(
                callbackURLString: callbackString,
                site: site,
                passport: "rawpassport"
            )
        ) { error in
            XCTAssertTrue(error is FoodleError)
        }
    }

    func testSSOTokenParsingQueryParamFormat() throws {
        let client = MoodleClient()
        let passport = "querypassport"
        let token = "querytoken"
        let privateToken = "queryprivate"
        let siteURL = "https://moodle.example.edu"

        let callbackString = buildCallback(
            siteURL: siteURL,
            passport: passport,
            token: token,
            privateToken: privateToken,
            format: .queryParam
        )
        let site = makeSite(baseURL: siteURL)

        let result = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackString,
            site: site,
            passport: passport
        )

        XCTAssertEqual(result.token, token)
        XCTAssertEqual(result.privateToken, privateToken)
    }

    func testSSOTokenParsingPercentEncodedBase64() throws {
        let client = MoodleClient()
        let passport = "encodedpassport"
        let token = "\u{00BF}" // Produces base64 with '/'
        let siteURL = "https://moodle.example.edu"
        let site = makeSite(baseURL: siteURL)

        let signature = MoodleClient.md5("\(siteURL)\(passport)")
        let payload = "\(signature):::\(token)"
        let base64 = Data(payload.utf8).base64EncodedString()
        let percentEncoded = base64.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let callbackString = "findle://token=\(percentEncoded)"

        let result = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackString,
            site: site,
            passport: passport
        )
        XCTAssertEqual(result.token, token)
    }

    func testSSOTokenParsingURLSafeBase64() throws {
        let client = MoodleClient()
        let passport = "safep"
        let token = "tok+en/with=special"
        let siteURL = "https://moodle.example.edu"
        let site = makeSite(baseURL: siteURL)

        let signature = MoodleClient.md5("\(siteURL)\(passport)")
        let payload = "\(signature):::\(token)"
        // URL-safe base64: replace + with -, / with _, remove padding
        let base64 = Data(payload.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let callbackString = "findle://token=\(base64)"

        let result = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackString,
            site: site,
            passport: passport
        )
        XCTAssertEqual(result.token, token)
    }

    // MARK: - Multi-Scheme Callback Tests

    func testSSOTokenParsingMoodleMobileScheme() throws {
        let client = MoodleClient()
        let passport = "mp"
        let token = "mt"
        let siteURL = "https://moodle.example.edu"

        let callbackString = buildCallback(scheme: "moodlemobile", siteURL: siteURL, passport: passport, token: token)
        let site = makeSite(baseURL: siteURL)

        let result = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackString,
            site: site,
            passport: passport
        )
        XCTAssertEqual(result.token, token)
    }

    func testSSOTokenParsingOpenLMSScheme() throws {
        let client = MoodleClient()
        let passport = "op"
        let token = "ot"
        let siteURL = "https://moodle.example.edu"

        let callbackString = buildCallback(scheme: "openlms", siteURL: siteURL, passport: passport, token: token)
        let site = makeSite(baseURL: siteURL)

        let result = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackString,
            site: site,
            passport: passport
        )
        XCTAssertEqual(result.token, token)
    }

    // MARK: - Error Cases

    func testSSOTokenParsingMalformedCallbackURL() {
        let client = MoodleClient()
        let site = makeSite()

        XCTAssertThrowsError(
            try client.parseTokenFromSSOCallback(
                callbackURLString: "findle://something-else",
                site: site,
                passport: "anypassport"
            )
        ) { error in
            XCTAssertTrue(error is FoodleError)
        }
    }

    func testSSOTokenParsingInvalidBase64Payload() {
        let client = MoodleClient()
        let site = makeSite()

        XCTAssertThrowsError(
            try client.parseTokenFromSSOCallback(
                callbackURLString: "findle://token=!!!not-base64!!!",
                site: site,
                passport: "anypassport"
            )
        ) { error in
            XCTAssertTrue(error is FoodleError)
        }
    }

    // MARK: - Token Extraction

    func testExtractTokenParamHostEquals() {
        let result = MoodleClient.extractTokenParam(from: "findle://token=abc123")
        XCTAssertEqual(result, "abc123")
    }

    func testExtractTokenParamQueryFormat() {
        let result = MoodleClient.extractTokenParam(from: "findle://token?token=abc123")
        XCTAssertEqual(result, "abc123")
    }

    func testExtractTokenParamNoToken() {
        let result = MoodleClient.extractTokenParam(from: "findle://something-else")
        XCTAssertNil(result)
    }

    func testExtractTokenParamAnyScheme() {
        let result = MoodleClient.extractTokenParam(from: "moodlemobile://token=xyz")
        XCTAssertEqual(result, "xyz")
    }

    // MARK: - Signature Candidate URLs

    func testSignatureCandidateURLsDeduplicates() {
        let site = makeSite(
            baseURL: "https://moodle.example.edu",
            wwwroot: "https://moodle.example.edu",
            httpswwwroot: "https://moodle.example.edu"
        )
        let candidates = MoodleClient.signatureCandidateURLs(for: site)
        // Should have: wwwroot/httpswwwroot (deduped to 1), baseURL (same, deduped), http alternate
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.contains("https://moodle.example.edu"))
        XCTAssertTrue(candidates.contains("http://moodle.example.edu"))
    }

    func testSignatureCandidateURLsIncludesAllVariants() {
        let site = makeSite(
            baseURL: "https://moodle.example.edu",
            wwwroot: "http://moodle.example.edu",
            httpswwwroot: "https://moodle.example.edu"
        )
        let candidates = MoodleClient.signatureCandidateURLs(for: site)
        XCTAssertTrue(candidates.contains("http://moodle.example.edu"))
        XCTAssertTrue(candidates.contains("https://moodle.example.edu"))
    }

    // MARK: - MD5

    func testMD5() {
        // Known MD5 hash of "hello"
        XCTAssertEqual(MoodleClient.md5("hello"), "5d41402abc4b2a76b9719d911017c592")
    }

    // MARK: - Login Type

    func testSiteLoginTypeSSO() {
        XCTAssertTrue(SiteLoginType.browser.requiresSSO)
        XCTAssertTrue(SiteLoginType.embedded.requiresSSO)
        XCTAssertFalse(SiteLoginType.app.requiresSSO)
    }

    func testSiteCapabilitiesRequiresSSO() {
        let ssoCapabilities = SiteCapabilities(loginType: .browser)
        XCTAssertTrue(ssoCapabilities.requiresSSO)

        let appCapabilities = SiteCapabilities(loginType: .app)
        XCTAssertFalse(appCapabilities.requiresSSO)
    }

    // MARK: - Module Response

    func testModuleResponseDecoding() throws {
        let json = """
        {
          "id": 2001,
          "name": "Course Syllabus",
          "modname": "resource",
          "modicon": null,
          "visible": 1,
          "contents": [
            {
              "type": "file",
              "filename": "syllabus.pdf",
              "filepath": "/",
              "filesize": 245760,
              "fileurl": "https://moodle.example.edu/file.php/1/syllabus.pdf",
              "timecreated": 1693526400,
              "timemodified": 1693526400,
              "mimetype": "application/pdf",
              "author": "Prof. Smith",
              "sortorder": 0
            }
          ]
        }
        """
        let data = json.data(using: .utf8)!
        let module = try JSONDecoder().decode(ModuleResponse.self, from: data)

        XCTAssertEqual(module.id, 2001)
        XCTAssertEqual(module.modname, "resource")
        XCTAssertEqual(module.contents?.count, 1)
        XCTAssertEqual(module.contents?[0].filename, "syllabus.pdf")
    }
}

private final class MockURLProtocol: URLProtocol {
    typealias RequestHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

    nonisolated(unsafe) static var requestHandler: RequestHandler?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            fatalError("MockURLProtocol.requestHandler was not set")
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
