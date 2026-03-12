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

    /// The SSO launch URL for browser-based authentication.
    /// - Parameter passport: A random string to verify the callback authenticity.
    /// - Returns: The URL to open in ASWebAuthenticationSession.
    public func ssoLaunchURL(passport: String) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("admin/tool/mobile/launch.php"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "service", value: "moodle_mobile_app"),
            URLQueryItem(name: "passport", value: passport),
            URLQueryItem(name: "urlscheme", value: MoodleSite.callbackScheme)
        ]
        return components.url!
    }

    /// The custom URL scheme used for SSO callbacks.
    public static let callbackScheme = "foodle"
}

/// How the site expects users to authenticate.
public enum SiteLoginType: Int, Sendable, Codable, Equatable {
    /// Standard username/password login via Moodle's own form.
    case app = 1
    /// Browser-based SSO (SAML, OAuth2, CAS, etc.) - opens system browser.
    case browser = 2
    /// Embedded browser SSO - can be handled in-app with ASWebAuthenticationSession.
    case embedded = 3

    /// Whether this login type requires a browser/web-based flow.
    public var requiresSSO: Bool {
        self != .app
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
    public var loginType: SiteLoginType
    public var launchURL: String?
    public var identityProviders: [IdentityProvider]

    public init(
        supportsWebServices: Bool = false,
        supportsMobileAPI: Bool = false,
        supportsFileDownload: Bool = false,
        moodleVersion: String? = nil,
        moodleRelease: String? = nil,
        siteName: String? = nil,
        loginType: SiteLoginType = .app,
        launchURL: String? = nil,
        identityProviders: [IdentityProvider] = []
    ) {
        self.supportsWebServices = supportsWebServices
        self.supportsMobileAPI = supportsMobileAPI
        self.supportsFileDownload = supportsFileDownload
        self.moodleVersion = moodleVersion
        self.moodleRelease = moodleRelease
        self.siteName = siteName
        self.loginType = loginType
        self.launchURL = launchURL
        self.identityProviders = identityProviders
    }

    public var isCompatible: Bool {
        supportsWebServices && supportsFileDownload
    }

    public var requiresSSO: Bool {
        loginType.requiresSSO
    }
}

/// An identity provider advertised by the Moodle site (e.g., Microsoft, Google).
public struct IdentityProvider: Sendable, Codable, Equatable {
    public let name: String
    public let iconURL: URL?
    public let url: URL

    public init(name: String, iconURL: URL? = nil, url: URL) {
        self.name = name
        self.iconURL = iconURL
        self.url = url
    }
}
