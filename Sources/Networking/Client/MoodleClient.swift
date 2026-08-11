// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain
import OSLog
import CommonCrypto

/// Native Moodle web services client implementing the LMSProvider protocol.
public final class MoodleClient: LMSProvider, Sendable {
    private let session: URLSession
    private let logger = Logger(subsystem: "es.amodrono.findle.networking", category: "MoodleClient")

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Site Validation

    public func validateSite(url: URL) async throws -> MoodleSite {
        try await validateSite(url: url) { _ in }
    }

    public func validateSite(
        url: URL,
        onProgress: @escaping @Sendable (SiteValidationProgress) async -> Void
    ) async throws -> MoodleSite {
        let normalizedURL = Self.normalizeURL(url)
        logger.info("Validating site: \(normalizedURL.absoluteString, privacy: .public)")

        try Task.checkCancellation()

        await onProgress(.checkingConfiguration)

        do {
            return try await fetchSiteInfo(baseURL: normalizedURL, requestPolicy: .interactiveValidation)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as FindleError {
            guard shouldAttemptCompatibilityProbe(after: error) else {
                throw error
            }
            logger.info("Public site config request failed; falling back to token endpoint compatibility probe")
        } catch {
            logger.info("Public site config request failed; falling back to token endpoint compatibility probe")
        }

        try Task.checkCancellation()
        await onProgress(.checkingCompatibility)

        return try await probeTokenEndpointCompatibility(
            baseURL: normalizedURL,
            requestPolicy: .interactiveCompatibilityProbe
        )
    }

    private func fetchSiteInfo(
        baseURL: URL,
        requestPolicy: RequestPolicy = .standard
    ) async throws -> MoodleSite {
        // Use ajax.php to get site info without authentication
        let ajaxURL = baseURL.appendingPathComponent("lib/ajax/service-nologin.php")
        var request = URLRequest(url: ajaxURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = requestPolicy.timeoutInterval

        let body: [[String: Any]] = [
            [
                "index": 0,
                "methodname": "tool_mobile_get_public_config",
                "args": [:] as [String: String]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await performRequest(request, policy: requestPolicy)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FindleError.siteUnreachable(url: baseURL)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw FindleError.requestFailed(
                statusCode: httpResponse.statusCode,
                detail: String(data: data, encoding: .utf8) ?? "Unknown"
            )
        }

        if let responses = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = responses.first {
            if let exception = first["exception"] as? [String: Any] {
                let detail = exception["message"] as? String ?? "Missing public site configuration."
                throw FindleError.siteIncompatible(reason: detail)
            }

            guard let resultData = first["data"] as? [String: Any] else {
                throw FindleError.invalidResponse(detail: "Missing public site configuration.")
            }

            let siteName = resultData["sitename"] as? String
            let release = resultData["release"] as? String
            let version = resultData["version"] as? String
            let launchURL = resultData["launchurl"] as? String
            let wwwroot = resultData["wwwroot"] as? String
            let httpswwwroot = resultData["httpswwwroot"] as? String

            // Parse login type: 1 = app, 2 = browser SSO, 3 = embedded SSO
            let typeOfLogin = resultData["typeoflogin"] as? Int ?? 1
            let loginType = SiteLoginType(rawValue: typeOfLogin) ?? .app

            // Parse identity providers (e.g., Microsoft, Google, Okta)
            var identityProviders: [IdentityProvider] = []
            if let providers = resultData["identityproviders"] as? [[String: Any]] {
                for provider in providers {
                    if let name = provider["name"] as? String,
                       let urlString = provider["url"] as? String,
                       let url = URL(string: urlString) {
                        let iconURL = (provider["iconurl"] as? String).flatMap { URL(string: $0) }
                        identityProviders.append(IdentityProvider(name: name, iconURL: iconURL, url: url))
                    }
                }
            }

            // Determine canonical base URL from discovered site root.
            // Priority: valid httpswwwroot > valid wwwroot > original baseURL.
            let canonicalBaseURL: URL = {
                if let https = httpswwwroot, let url = URL(string: https), url.scheme == "https" {
                    return Self.normalizeURL(url)
                }
                if let www = wwwroot, let url = URL(string: www) {
                    return Self.normalizeURL(url)
                }
                return baseURL
            }()

            logger.info("Site login type: \(typeOfLogin) (\(loginType.requiresSSO ? "SSO" : "password", privacy: .public))")
            if let launchURL {
                logger.info("Discovered launchurl: \(launchURL, privacy: .public)")
            } else {
                logger.info("No launchurl advertised by site")
            }
            if let wwwroot {
                logger.info("Discovered wwwroot: \(wwwroot, privacy: .public)")
            }
            if let httpswwwroot {
                logger.info("Discovered httpswwwroot: \(httpswwwroot, privacy: .public)")
            }
            if canonicalBaseURL != baseURL {
                logger.info("Canonical base URL set to discovered root: \(canonicalBaseURL.absoluteString, privacy: .public)")
            }
            if !identityProviders.isEmpty {
                logger.info("Identity providers: \(identityProviders.map(\.name).joined(separator: ", "), privacy: .public)")
            }

            let capabilities = SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true,
                moodleVersion: version,
                moodleRelease: release,
                siteName: siteName,
                loginType: loginType,
                launchURL: launchURL,
                identityProviders: identityProviders,
                wwwroot: wwwroot,
                httpswwwroot: httpswwwroot,
                showLoginForm: true
            )

            return MoodleSite(
                displayName: siteName ?? canonicalBaseURL.host ?? "Moodle",
                baseURL: canonicalBaseURL,
                capabilities: capabilities
            )
        }

        throw FindleError.invalidResponse(detail: "Could not decode Moodle public site configuration.")
    }

    private func probeTokenEndpointCompatibility(
        baseURL: URL,
        requestPolicy: RequestPolicy
    ) async throws -> MoodleSite {
        let infoURL = baseURL.appendingPathComponent("login/token.php")
        var request = URLRequest(url: infoURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = "username=_check_&password=_check_&service=moodle_mobile_app".data(using: .utf8)
        request.timeoutInterval = requestPolicy.timeoutInterval

        let (data, response) = try await performRequest(request, policy: requestPolicy)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FindleError.siteUnreachable(url: baseURL)
        }

        guard httpResponse.statusCode == 200 else {
            throw FindleError.siteIncompatible(reason: "Could not verify Moodle web services at this URL.")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FindleError.siteIncompatible(reason: "Could not verify Moodle web services at this URL.")
        }

        let errorCode = json["errorcode"] as? String
        if errorCode == "enablewsdescription" {
            throw FindleError.webServicesDisabled
        }

        let isValidMoodle = errorCode == "invalidlogin"
            || errorCode == "sitemaintenance"
            || json["token"] != nil

        guard isValidMoodle else {
            throw FindleError.siteIncompatible(reason: "Could not verify Moodle web services at this URL.")
        }

        logger.info("Token endpoint compatibility probe succeeded")
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

    private func shouldAttemptCompatibilityProbe(after error: FindleError) -> Bool {
        switch error {
        case .networkUnavailable, .timeout, .siteUnreachable, .webServicesDisabled:
            return false
        default:
            return true
        }
    }

    // MARK: - Authentication

    public func authenticate(site: MoodleSite, username: String, password: String) async throws -> AuthToken {
        logger.info("Authenticating user \(username, privacy: .private) at \(site.baseURL.host ?? "", privacy: .public)")

        // Build the body explicitly so '+' in a password isn't double-decoded
        // as a space by Moodle. URLQueryItem's default escaping leaves '+'
        // unescaped, which Moodle's form decoder then interprets as a space.
        var request = URLRequest(url: site.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode([
            "username": username,
            "password": password,
            "service": "moodle_mobile_app"
        ])

        let (data, _) = try await performRequest(request)
        let tokenResponse = try Self.makeDecoder().decode(TokenResponse.self, from: data)

        if let error = tokenResponse.error {
            if error.contains("invalidlogin") || tokenResponse.errorcode == "invalidlogin" {
                throw FindleError.invalidCredentials
            }
            throw FindleError.siteIncompatible(reason: error)
        }

        guard let token = tokenResponse.token else {
            throw FindleError.invalidResponse(detail: "No token in authentication response.")
        }

        return AuthToken(token: token, privateToken: tokenResponse.privatetoken)
    }

    // MARK: - SSO Token Parsing

    public func parseTokenFromSSOCallback(callbackURLString: String, site: MoodleSite, passport: String) throws -> AuthToken {
        logger.info("Parsing SSO callback")

        guard let base64String = Self.extractTokenParam(from: callbackURLString) else {
            throw FindleError.invalidResponse(detail: "SSO callback URL has unexpected format.")
        }

        return try decodeTokenPayload(base64String, site: site, passport: passport)
    }

    /// Extract the base64 token parameter from a raw callback URL string.
    /// Handles both `scheme://token=<base64>` and `scheme://token?token=<base64>` formats,
    /// and accepts any URL scheme (findle, moodlemobile, openlms, etc.).
    static func extractTokenParam(from urlString: String) -> String? {
        // Format 1: scheme://token=<base64> — the token is everything after "://token="
        if let range = urlString.range(of: "://token=") {
            let value = String(urlString[range.upperBound...])
            return value.isEmpty ? nil : value
        }

        // Format 2: scheme://token?token=<base64> (URL query param)
        if let components = URLComponents(string: urlString),
           let tokenItem = components.queryItems?.first(where: { $0.name == "token" }) {
            return tokenItem.value
        }

        return nil
    }

    private func decodeTokenPayload(_ base64String: String, site: MoodleSite, passport: String) throws -> AuthToken {
        let decodedPercentEscapes = base64String.removingPercentEncoding ?? base64String

        // The base64 string may be URL-safe encoded; normalize it
        var base64 = decodedPercentEscapes
            .replacingOccurrences(of: " ", with: "+")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        // Pad if necessary
        let remainder = base64.count % 4
        if remainder > 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }

        guard let data = Data(base64Encoded: base64),
              let decoded = String(data: data, encoding: .utf8) else {
            throw FindleError.invalidResponse(detail: "Could not decode SSO token payload.")
        }

        // Moodle payload format: md5(siteURL + passport):::token[:::privatetoken]
        let parts = decoded.components(separatedBy: ":::")
        guard parts.count >= 2 else {
            throw FindleError.invalidResponse(detail: "SSO token payload has unexpected format.")
        }

        let signature = parts[0]
        let token = parts[1]
        let privateToken = parts.count > 2 ? parts[2] : nil

        // Build candidate site URLs for signature validation.
        // Moodle computes md5(wwwroot + passport), so we try all known URL variants.
        let candidateURLs = Self.signatureCandidateURLs(for: site)

        let matched = candidateURLs.contains { candidate in
            let expected = Self.md5("\(candidate)\(passport)")
            return expected == signature
        }

        guard matched else {
            logger.error("SSO signature mismatch - none of the candidate URLs matched")
            throw FindleError.invalidResponse(detail: "SSO security verification failed.")
        }

        logger.info("SSO token obtained successfully")
        return AuthToken(token: token, privateToken: privateToken)
    }

    /// Build an ordered list of candidate site URL strings for SSO signature validation.
    /// Moodle computes `md5(wwwroot + passport)` so we try the known URL variants.
    static func signatureCandidateURLs(for site: MoodleSite) -> [String] {
        var candidates: [String] = []

        // Prefer the discovered wwwroot and httpswwwroot first.
        if let wwwroot = site.capabilities.wwwroot {
            candidates.append(wwwroot)
        }
        if let httpswwwroot = site.capabilities.httpswwwroot {
            candidates.append(httpswwwroot)
        }

        // The canonical base URL.
        let base = site.baseURL.absoluteString
        candidates.append(base)

        // Try the HTTP/HTTPS alternate of the canonical URL.
        if base.hasPrefix("https://") {
            candidates.append("http://" + base.dropFirst("https://".count))
        } else if base.hasPrefix("http://") {
            candidates.append("https://" + base.dropFirst("http://".count))
        }

        // Deduplicate while preserving order.
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// Compute the MD5 hex digest of a string.
    static func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { body in
            _ = CC_MD5(body.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
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
            // Pick the first image-type overview file as the course cover.
            let imageURL = course.overviewfiles?
                .first { ($0.mimetype ?? "").hasPrefix("image/") }
                .flatMap { $0.fileurl }
                // Moodle cover filenames often contain spaces / accented UTF-8,
                // which plain URL(string:) rejects — encode invalid characters.
                .flatMap { URL(string: $0, encodingInvalidCharacters: true) }

            return MoodleCourse(
                id: course.id,
                shortName: course.shortname,
                fullName: course.fullname,
                summary: course.summary,
                categoryID: course.category,
                startDate: course.startdate.flatMap { Date(timeIntervalSince1970: TimeInterval($0)) },
                endDate: course.enddate.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                lastAccessed: course.lastaccess.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                visible: (course.visible ?? 1) == 1,
                siteID: site.id,
                imageURL: imageURL
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

    // MARK: - Coursework Tracking (read-only)

    public func fetchAssignments(site: MoodleSite, token: AuthToken, courseIDs: [Int]) async throws -> [MoodleAssignment] {
        guard !courseIDs.isEmpty else { return [] }
        let response: AssignmentsResponse = try await callWebService(
            site: site,
            token: token,
            function: "mod_assign_get_assignments",
            params: Self.indexedParams("courseids", courseIDs)
        )
        return response.courses.flatMap { course in
            course.assignments.map { item in
                MoodleAssignment(
                    id: item.id,
                    courseID: item.course,
                    name: item.name,
                    dueDate: Self.timestamp(item.duedate),
                    cutoffDate: Self.timestamp(item.cutoffdate)
                )
            }
        }
    }

    /// Submission/grading state for one assignment. Best-effort — sites may
    /// restrict this function, so callers should tolerate a thrown error.
    public func fetchSubmissionStatus(site: MoodleSite, token: AuthToken, assignmentID: Int) async throws -> (submitted: Bool, graded: Bool, grade: String?) {
        let response: SubmissionStatusResponse = try await callWebService(
            site: site,
            token: token,
            function: "mod_assign_get_submission_status",
            params: ["assignid": String(assignmentID)]
        )
        let submitted = response.lastattempt?.submission?.status == "submitted"
        let graded = response.lastattempt?.gradingstatus == "graded"
        return (submitted, graded, response.feedback?.grade?.grade)
    }

    public func fetchGrades(site: MoodleSite, token: AuthToken, courseID: Int, userID: Int) async throws -> [MoodleGradeItem] {
        let response: GradeItemsResponse = try await callWebService(
            site: site,
            token: token,
            function: "gradereport_user_get_grade_items",
            params: ["courseid": String(courseID), "userid": String(userID)]
        )
        return response.usergrades.flatMap { userGrade in
            userGrade.gradeitems.map { item in
                MoodleGradeItem(
                    id: item.id,
                    courseID: userGrade.courseid,
                    itemName: (item.itemname?.isEmpty == false ? item.itemname! : "Course total"),
                    grade: item.gradeformatted,
                    percentage: item.percentageformatted,
                    feedback: Self.stripHTML(item.feedback)
                )
            }
        }
    }

    public func fetchQuizzes(site: MoodleSite, token: AuthToken, courseIDs: [Int]) async throws -> [MoodleQuiz] {
        guard !courseIDs.isEmpty else { return [] }
        let response: QuizzesResponse = try await callWebService(
            site: site,
            token: token,
            function: "mod_quiz_get_quizzes_by_courses",
            params: Self.indexedParams("courseids", courseIDs)
        )
        return response.quizzes.map { quiz in
            MoodleQuiz(
                id: quiz.id,
                courseID: quiz.course,
                name: quiz.name,
                openDate: Self.timestamp(quiz.timeopen),
                closeDate: Self.timestamp(quiz.timeclose),
                timeLimit: (quiz.timelimit ?? 0) > 0 ? quiz.timelimit : nil
            )
        }
    }

    public func fetchQuizAttempts(site: MoodleSite, token: AuthToken, quizID: Int, userID: Int) async throws -> [MoodleQuizAttempt] {
        let response: QuizAttemptsResponse = try await callWebService(
            site: site,
            token: token,
            function: "mod_quiz_get_user_attempts",
            params: ["quizid": String(quizID), "userid": String(userID), "status": "all"]
        )
        return response.attempts.map { attempt in
            MoodleQuizAttempt(
                id: attempt.id,
                quizID: attempt.quiz,
                attemptNumber: attempt.attempt,
                state: attempt.state,
                sumGrades: attempt.sumgrades,
                startTime: Self.timestamp(attempt.timestart),
                finishTime: Self.timestamp(attempt.timefinish)
            )
        }
    }

    private static func indexedParams(_ key: String, _ values: [Int]) -> [String: String] {
        var params: [String: String] = [:]
        for (index, value) in values.enumerated() {
            params["\(key)[\(index)]"] = String(value)
        }
        return params
    }

    private static func timestamp(_ value: Int?) -> Date? {
        guard let value, value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value))
    }

    private static func stripHTML(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - File Download

    public func downloadFile(url: URL, token: AuthToken, destination: URL) async throws {
        let request = authenticatedFileRequest(fileURL: url, token: token)

        let (tempURL, response) = try await session.download(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw FindleError.downloadFailed(itemID: url.lastPathComponent, reason: "HTTP \(statusCode)")
        }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: tempURL, to: destination)
    }

    public func authenticatedFileRequest(fileURL: URL, token: AuthToken) -> URLRequest {
        // Moodle's pluginfile.php accepts the token via either $_GET or $_POST.
        // Send it via POST body so the token doesn't end up in URL logs, the
        // Referer header on CDN redirects, or URLSession metrics. The URL
        // itself stays clean.
        var request = URLRequest(url: fileURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(["token": token.token])
        return request
    }

    // MARK: - Web Service Call

    private func callWebService<T: Decodable>(
        site: MoodleSite,
        token: AuthToken,
        function: String,
        params: [String: String] = [:]
    ) async throws -> T {
        // POST the credentials and parameters in the body so wstoken never
        // ends up in URL logs, proxy access logs, or crash reports. Moodle's
        // webservice/rest/server.php accepts either GET or POST.
        var body: [String: String] = [
            "wstoken": token.token,
            "wsfunction": function,
            "moodlewsrestformat": "json"
        ]
        for (key, value) in params {
            body[key] = value
        }

        var request = URLRequest(url: site.webServiceURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(body)

        let (data, response) = try await performRequest(request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FindleError.invalidResponse(detail: "Non-HTTP response.")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw FindleError.requestFailed(
                statusCode: httpResponse.statusCode,
                detail: String(data: data, encoding: .utf8) ?? "Unknown"
            )
        }

        // Check for Moodle-level errors in the JSON
        if let errorResponse = try? Self.makeDecoder().decode(MoodleErrorResponse.self, from: data) {
            if errorResponse.errorcode != nil {
                if errorResponse.errorcode == "invalidtoken" || errorResponse.errorcode == "accessexception" {
                    throw FindleError.tokenExpired
                }
                throw FindleError.requestFailed(
                    statusCode: httpResponse.statusCode,
                    detail: errorResponse.message ?? errorResponse.errorcode ?? "Unknown Moodle error"
                )
            }
        }

        return try Self.makeDecoder().decode(T.self, from: data)
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    // MARK: - Request Execution

    private enum RequestPolicy {
        case standard
        case interactiveValidation
        case interactiveCompatibilityProbe

        var retryCount: Int {
            switch self {
            case .standard:
                return 3
            case .interactiveValidation, .interactiveCompatibilityProbe:
                return 1
            }
        }

        var timeoutInterval: TimeInterval {
            switch self {
            case .standard:
                return 15
            case .interactiveValidation:
                return 6
            case .interactiveCompatibilityProbe:
                return 4
            }
        }

        var mapsHostErrorsToSiteUnreachable: Bool {
            switch self {
            case .standard:
                return false
            case .interactiveValidation, .interactiveCompatibilityProbe:
                return true
            }
        }
    }

    private func performRequest(
        _ request: URLRequest,
        policy: RequestPolicy = .standard
    ) async throws -> (Data, URLResponse) {
        var request = request
        if request.timeoutInterval <= 0 {
            request.timeoutInterval = policy.timeoutInterval
        }

        var lastError: Error?
        for attempt in 0..<policy.retryCount {
            try Task.checkCancellation()

            do {
                return try await session.data(for: request)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                lastError = error

                if let mappedError = mapTransportError(error, requestURL: request.url, policy: policy) {
                    throw mappedError
                }

                if attempt < policy.retryCount - 1 {
                    let delay = pow(2.0, Double(attempt)) * 0.5
                    try await Task.sleep(for: .seconds(delay))
                    logger.debug("Retrying request (attempt \(attempt + 1))")
                }
            } catch {
                throw error
            }
        }

        throw lastError ?? FindleError.networkUnavailable
    }

    private func mapTransportError(
        _ error: URLError,
        requestURL: URL?,
        policy: RequestPolicy
    ) -> FindleError? {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return .networkUnavailable
        case .timedOut:
            return .timeout
        case .badURL, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                .secureConnectionFailed, .appTransportSecurityRequiresSecureConnection,
                .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                .serverCertificateNotYetValid, .clientCertificateRejected,
                .clientCertificateRequired:
            if policy.mapsHostErrorsToSiteUnreachable, let requestURL {
                return .siteUnreachable(url: requestURL)
            }
            return nil
        default:
            return nil
        }
    }

    // MARK: - Form Encoding

    /// Form-encode a dictionary into the body of an `application/x-www-form-urlencoded`
    /// request. Uses an explicit allowed set that excludes `+`, `&`, `=`, `?`, and `#` so
    /// special characters in passwords or other values can't be misinterpreted on the
    /// receiving side.
    static func formEncode(_ fields: [String: String]) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let parts: [String] = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return parts.joined(separator: "&").data(using: .utf8)
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

    // MARK: - Diagnostics

    /// Log a privacy-safe summary of a site's SSO capabilities for manual verification.
    public func logSSODiagnostics(for site: MoodleSite) {
        logger.info("SSO diagnostics for \(site.displayName, privacy: .public)")
        logger.info("  Base URL: \(site.baseURL.absoluteString, privacy: .public)")
        logger.info("  Login type: \(site.capabilities.loginType.rawValue) (requiresSSO: \(site.capabilities.loginType.requiresSSO, privacy: .public))")
        logger.info("  Has advertised launchURL: \(site.capabilities.launchURL != nil, privacy: .public)")
        logger.debug("  Advertised launchURL: \(site.capabilities.launchURL ?? "<none>", privacy: .private)")
        logger.info("  wwwroot: \(site.capabilities.wwwroot ?? "<none>", privacy: .public)")
        logger.info("  httpswwwroot: \(site.capabilities.httpswwwroot ?? "<none>", privacy: .public)")
        logger.info("  Identity providers: \(site.capabilities.identityProviders.map(\.name).joined(separator: ", "), privacy: .public)")
        logger.info("  Moodle version: \(site.capabilities.moodleVersion ?? "unknown", privacy: .public)")
        logger.info("  Moodle release: \(site.capabilities.moodleRelease ?? "unknown", privacy: .public)")
    }
}
