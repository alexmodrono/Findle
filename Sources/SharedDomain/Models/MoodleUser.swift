import Foundation

/// An authenticated Moodle user.
public struct MoodleUser: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let username: String
    public let fullName: String
    public let email: String?
    public let profileImageURL: URL?
    public let siteID: String

    public init(
        id: Int,
        username: String,
        fullName: String,
        email: String? = nil,
        profileImageURL: URL? = nil,
        siteID: String
    ) {
        self.id = id
        self.username = username
        self.fullName = fullName
        self.email = email
        self.profileImageURL = profileImageURL
        self.siteID = siteID
    }
}
