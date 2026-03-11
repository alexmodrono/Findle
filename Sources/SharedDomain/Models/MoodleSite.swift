import Foundation

/// Represents a Moodle or Open LMS server instance.
public struct MoodleSite: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let baseURL: URL
    public let capabilities: SiteCapabilities

    public init(id: String = UUID().uuidString, displayName: String, baseURL: URL, capabilities: SiteCapabilities = .init()) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.capabilities = capabilities
    }

    /// The web services endpoint for this site.
    public var webServiceURL: URL {
        baseURL.appendingPathComponent("webservice/rest/server.php")
    }

    /// The token endpoint for this site.
    public var tokenURL: URL {
        baseURL.appendingPathComponent("login/token.php")
    }
}

/// Describes the capabilities detected on a Moodle site.
public struct SiteCapabilities: Sendable, Codable, Equatable {
    public var supportsWebServices: Bool
    public var supportsMobileAPI: Bool
    public var supportsFileDownload: Bool
    public var moodleVersion: String?
    public var moodleRelease: String?
    public var siteName: String?

    public init(
        supportsWebServices: Bool = false,
        supportsMobileAPI: Bool = false,
        supportsFileDownload: Bool = false,
        moodleVersion: String? = nil,
        moodleRelease: String? = nil,
        siteName: String? = nil
    ) {
        self.supportsWebServices = supportsWebServices
        self.supportsMobileAPI = supportsMobileAPI
        self.supportsFileDownload = supportsFileDownload
        self.moodleVersion = moodleVersion
        self.moodleRelease = moodleRelease
        self.siteName = siteName
    }

    public var isCompatible: Bool {
        supportsWebServices && supportsFileDownload
    }
}
