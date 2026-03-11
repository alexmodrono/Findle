import Foundation
import SharedDomain
import OSLog

/// Native Moodle web services client implementing the LMSProvider protocol.
public final class MoodleClient: LMSProvider, @unchecked Sendable {
    private let session: URLSession
    private let logger = Logger(subsystem: "com.foodle.networking", category: "MoodleClient")
    private let decoder: JSONDecoder

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .secondsSince1970
    }

    // MARK: - Site Validation

    public func validateSite(url: URL) async throws -> MoodleSite {
        let normalizedURL = Self.normalizeURL(url)
        logger.info("Validating site: \(normalizedURL.absoluteString, privacy: .public)")

        // Try to get site info via the mobile web services check
        let infoURL = normalizedURL.appendingPathComponent("login/token.php")
        var request = URLRequest(url: infoURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // Send a minimal request to check if the endpoint exists
        request.httpBody = "username=_check_&password=_check_&service=moodle_mobile_app".data(using: .utf8)
        request.timeoutInterval = 15

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FoodleError.siteUnreachable(url: normalizedURL)
        }

        // Even with bad credentials, a valid Moodle site returns JSON with an error
        // A non-Moodle site returns HTML or a different status code
        if httpResponse.statusCode == 200 {
            // Try to parse the response - if it's JSON, it's likely Moodle
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Check for Moodle-specific error codes
                let errorCode = json["errorcode"] as? String
                let isValidMoodle = errorCode == "invalidlogin"
                    || errorCode == "enablewsdescription"
                    || errorCode == "sitemaintenance"
                    || json["token"] != nil

                if !isValidMoodle && errorCode == "enablewsdescription" {
                    throw FoodleError.webServicesDisabled
                }

                // Now try to get actual site info
                return try await fetchSiteInfo(baseURL: normalizedURL)
            }
        }

        // Try a secondary check - the site info API
        do {
            return try await fetchSiteInfo(baseURL: normalizedURL)
        } catch {
            throw FoodleError.siteIncompatible(reason: "Could not verify Moodle web services at this URL.")
        }
    }

    private func fetchSiteInfo(baseURL: URL) async throws -> MoodleSite {
        // Use ajax.php to get site info without authentication
        let ajaxURL = baseURL.appendingPathComponent("lib/ajax/service-nologin.php")
        var request = URLRequest(url: ajaxURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [[String: Any]] = [
            [
                "index": 0,
                "methodname": "tool_mobile_get_public_config",
                "args": [:] as [String: String]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await performRequest(request)

        if let responses = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = responses.first,
           let resultData = first["data"] as? [String: Any] {
            let siteName = resultData["sitename"] as? String
            let release = resultData["release"] as? String
            let version = resultData["version"] as? String

            let capabilities = SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true,
                moodleVersion: version,
                moodleRelease: release,
                siteName: siteName
            )

            return MoodleSite(
                displayName: siteName ?? baseURL.host ?? "Moodle",
                baseURL: baseURL,
                capabilities: capabilities
            )
        }

        // Fallback: assume basic compatibility
        return MoodleSite(
            displayName: baseURL.host ?? "Moodle",
            baseURL: baseURL,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: false,
                supportsFileDownload: true
            )
        )
    }

    // MARK: - Authentication

    public func authenticate(site: MoodleSite, username: String, password: String) async throws -> AuthToken {
        logger.info("Authenticating user \(username, privacy: .private) at \(site.baseURL.host ?? "", privacy: .public)")

        var components = URLComponents(url: site.tokenURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
            URLQueryItem(name: "service", value: "moodle_mobile_app")
        ]

        var request = URLRequest(url: site.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, _) = try await performRequest(request)
        let tokenResponse = try decoder.decode(TokenResponse.self, from: data)

        if let error = tokenResponse.error {
            if error.contains("invalidlogin") || tokenResponse.errorcode == "invalidlogin" {
                throw FoodleError.invalidCredentials
            }
            throw FoodleError.siteIncompatible(reason: error)
        }

        guard let token = tokenResponse.token else {
            throw FoodleError.invalidResponse(detail: "No token in authentication response.")
        }

        return AuthToken(token: token, privateToken: tokenResponse.privatetoken)
    }

    // MARK: - User Info

    public func fetchUserInfo(site: MoodleSite, token: AuthToken) async throws -> MoodleUser {
        let response: SiteInfoResponse = try await callWebService(
            site: site,
            token: token,
            function: "core_webservice_get_site_info"
        )

        return MoodleUser(
            id: response.userid,
            username: response.username,
            fullName: response.fullname,
            email: nil,
            profileImageURL: response.userpictureurl.flatMap { URL(string: $0) },
            siteID: site.id
        )
    }

    // MARK: - Courses

    public func fetchCourses(site: MoodleSite, token: AuthToken, userID: Int) async throws -> [MoodleCourse] {
        let response: [CourseResponse] = try await callWebService(
            site: site,
            token: token,
            function: "core_enrol_get_users_courses",
            params: ["userid": String(userID)]
        )

        return response.map { course in
            MoodleCourse(
                id: course.id,
                shortName: course.shortname,
                fullName: course.fullname,
                summary: course.summary,
                categoryID: course.category,
                startDate: course.startdate.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) },
                endDate: course.enddate.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                lastAccessed: course.lastaccess.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                visible: (course.visible ?? 1) == 1,
                siteID: site.id
            )
        }
    }

    // MARK: - Course Contents

    public func fetchCourseContents(site: MoodleSite, token: AuthToken, courseID: Int) async throws -> [MoodleSection] {
        let response: [SectionResponse] = try await callWebService(
            site: site,
            token: token,
            function: "core_course_get_contents",
            params: ["courseid": String(courseID)]
        )

        return response.map { section in
            MoodleSection(
                id: section.id,
                courseID: courseID,
                name: section.name,
                summary: section.summary,
                sectionNumber: section.section,
                visible: (section.visible ?? 1) == 1,
                modules: section.modules.map { mod in
                    MoodleModule(
                        id: mod.id,
                        name: mod.name,
                        modName: mod.modname,
                        modIcon: mod.modicon.flatMap { URL(string: $0) },
                        visible: (mod.visible ?? 1) == 1,
                        contents: (mod.contents ?? []).map { content in
                            MoodleFileContent(
                                type: content.type,
                                fileName: content.filename,
                                filePath: content.filepath,
                                fileSize: content.filesize ?? 0,
                                fileURL: content.fileurl.flatMap { URL(string: $0) },
                                timeCreated: content.timecreated.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) },
                                timeModified: content.timemodified.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) },
                                mimeType: content.mimetype,
                                author: content.author,
                                sortOrder: content.sortorder
                            )
                        }
                    )
                }
            )
        }
    }

    // MARK: - File Download

    public func downloadFile(url: URL, token: AuthToken, destination: URL) async throws {
        let authenticatedURL = authenticatedFileURL(fileURL: url, token: token)
        let request = URLRequest(url: authenticatedURL)

        let (tempURL, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw FoodleError.downloadFailed(itemID: url.lastPathComponent, reason: "HTTP \(statusCode)")
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: tempURL, to: destination)
    }

    public func authenticatedFileURL(fileURL: URL, token: AuthToken) -> URL {
        guard var components = URLComponents(url: fileURL, resolvingAgainstBaseURL: false) else {
            return fileURL
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "token", value: token.token))
        components.queryItems = items
        return components.url ?? fileURL
    }

    // MARK: - Web Service Call

    private func callWebService<T: Decodable>(
        site: MoodleSite,
        token: AuthToken,
        function: String,
        params: [String: String] = [:]
    ) async throws -> T {
        var components = URLComponents(url: site.webServiceURL, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "wstoken", value: token.token),
            URLQueryItem(name: "wsfunction", value: function),
            URLQueryItem(name: "moodlewsrestformat", value: "json")
        ]
        for (key, value) in params {
            queryItems.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw FoodleError.internalError(detail: "Could not construct web service URL.")
        }

        let request = URLRequest(url: url)
        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FoodleError.invalidResponse(detail: "Non-HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw FoodleError.requestFailed(
                statusCode: httpResponse.statusCode,
                detail: String(data: data, encoding: .utf8) ?? "Unknown"
            )
        }

        // Check for Moodle-level errors in the JSON
        if let errorResponse = try? decoder.decode(MoodleErrorResponse.self, from: data) {
            if errorResponse.errorcode != nil {
                if errorResponse.errorcode == "invalidtoken" || errorResponse.errorcode == "accessexception" {
                    throw FoodleError.tokenExpired
                }
                throw FoodleError.requestFailed(
                    statusCode: httpResponse.statusCode,
                    detail: errorResponse.message ?? errorResponse.errorcode ?? "Unknown Moodle error"
                )
            }
        }

        return try decoder.decode(T.self, from: data)
    }

    // MARK: - Request Execution

    private func performRequest(_ request: URLRequest, retryCount: Int = 3) async throws -> (Data, URLResponse) {
        var lastError: Error?
        for attempt in 0..<retryCount {
            do {
                return try await session.data(for: request)
            } catch let error as URLError {
                lastError = error
                if error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
                    throw FoodleError.networkUnavailable
                }
                if error.code == .timedOut {
                    throw FoodleError.timeout
                }
                if attempt < retryCount - 1 {
                    let delay = pow(2.0, Double(attempt)) * 0.5
                    try await Task.sleep(for: .seconds(delay))
                    logger.debug("Retrying request (attempt \(attempt + 1))")
                }
            } catch {
                throw error
            }
        }
        throw lastError ?? FoodleError.networkUnavailable
    }

    // MARK: - URL Normalization

    static func normalizeURL(_ url: URL) -> URL {
        var urlString = url.absoluteString
        if !urlString.hasPrefix("http://") && !urlString.hasPrefix("https://") {
            urlString = "https://" + urlString
        }
        while urlString.hasSuffix("/") {
            urlString = String(urlString.dropLast())
        }
        return URL(string: urlString) ?? url
    }
}
