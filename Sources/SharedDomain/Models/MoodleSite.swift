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

    /// The custom URL scheme used for SSO callbacks.
    public static let callbackScheme = "findle"

    /// All URL schemes recognized as valid SSO callbacks.
    /// Moodle/Open LMS may redirect to branded schemes depending on the site's
    /// mobile app configuration. These are registered with WKWebView so the
    /// navigation delegate intercepts them instead of the system URL handler.
    public static let acceptedCallbackSchemes: Set<String> = [
        "findle",
        "foodle",
        "moodlemobile",
        "openlms",
        "ltgopenlmsapp",
    ]
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

    /// The `wwwroot` field from `tool_mobile_get_public_config`.
    /// This is the canonical site root URL as known by the Moodle instance.
    public var wwwroot: String?

    /// The `httpswwwroot` field from `tool_mobile_get_public_config`.
    /// The HTTPS variant of the site root, if available.
    public var httpswwwroot: String?

    /// Whether the site advertises that a login form should be shown
    /// (`enablemobilewebservice` / config flag). Defaults to `true`.
    public var showLoginForm: Bool

    public init(
        supportsWebServices: Bool = false,
        supportsMobileAPI: Bool = false,
        supportsFileDownload: Bool = false,
        moodleVersion: String? = nil,
        moodleRelease: String? = nil,
        siteName: String? = nil,
        loginType: SiteLoginType = .app,
        launchURL: String? = nil,
        identityProviders: [IdentityProvider] = [],
        wwwroot: String? = nil,
        httpswwwroot: String? = nil,
        showLoginForm: Bool = true
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
        self.wwwroot = wwwroot
        self.httpswwwroot = httpswwwroot
        self.showLoginForm = showLoginForm
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
