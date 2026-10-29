// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain

/// High-level progress states emitted while validating a Moodle site.
public enum SiteValidationProgress: Sendable {
    case checkingConfiguration
    case checkingCompatibility
}

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

    /// Fetch a complete content tree (sections and modules) for a course.
    /// Throw if the response is incomplete or entries cannot be mapped safely:
    /// sync interprets absent items in a successful result as remote deletions.
    func fetchCourseContents(site: MoodleSite, token: AuthToken, courseID: Int) async throws -> [MoodleSection]

    /// Download from the selected site's HTTPS origin. Cross-origin redirects
    /// must be rejected before forwarding credentials, including POST bodies.
    func downloadFile(url: URL, site: MoodleSite, token: AuthToken, destination: URL) async throws

    /// Validate the destination before reading the token. The token stays out
    /// of the URL; callers must also enforce the site's origin on redirects.
    func authenticatedFileRequest(fileURL: URL, site: MoodleSite, token: AuthToken) throws -> URLRequest

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
