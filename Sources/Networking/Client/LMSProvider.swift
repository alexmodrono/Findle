import Foundation
import SharedDomain

/// Protocol for LMS backend providers. Moodle is the primary implementation;
/// additional backends (Canvas, Blackboard, etc.) can be added by conforming to this protocol.
public protocol LMSProvider: Sendable {
    /// Validate that the server at the given URL is a compatible LMS instance.
    func validateSite(url: URL) async throws -> MoodleSite

    /// Authenticate with username/password and return a token.
    func authenticate(site: MoodleSite, username: String, password: String) async throws -> AuthToken

    /// Parse a token from an SSO callback URL.
    ///
    /// Moodle redirects to `<scheme>://token=<base64>` where the base64 decodes to
    /// `md5(siteURL + passport):::token[:::privatetoken]`. The signature is validated
    /// against the site's known URLs.
    ///
    /// - Parameters:
    ///   - callbackURLString: The raw callback URL string (may use any recognized scheme).
    ///   - site: The Moodle site that initiated the SSO flow.
    ///   - passport: The random passport nonce sent in the launch URL.
    func parseTokenFromSSOCallback(callbackURLString: String, site: MoodleSite, passport: String) throws -> AuthToken

    /// Fetch info about the authenticated user.
    func fetchUserInfo(site: MoodleSite, token: AuthToken) async throws -> MoodleUser

    /// Fetch courses accessible to the authenticated user.
    func fetchCourses(site: MoodleSite, token: AuthToken, userID: Int) async throws -> [MoodleCourse]

    /// Fetch the content tree (sections and modules) for a course.
    func fetchCourseContents(site: MoodleSite, token: AuthToken, courseID: Int) async throws -> [MoodleSection]

    /// Download a file to a local path.
    func downloadFile(url: URL, token: AuthToken, destination: URL) async throws

    /// Construct an authenticated download URL for a file.
    func authenticatedFileURL(fileURL: URL, token: AuthToken) -> URL
}

/// Represents an authentication token for a Moodle session.
public struct AuthToken: Sendable, Codable, Equatable {
    public let token: String
    public let privateToken: String?
    public let issuedAt: Date

    public init(token: String, privateToken: String? = nil, issuedAt: Date = Date()) {
        self.token = token
        self.privateToken = privateToken
        self.issuedAt = issuedAt
    }
}
