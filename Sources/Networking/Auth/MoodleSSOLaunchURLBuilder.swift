import Foundation
import SharedDomain
import OSLog

/// Result of building an SSO launch URL, including the source used.
public struct MoodleSSOLaunchURLBuildResult: Sendable {
    public let url: URL
    public let source: Source

    public enum Source: Sendable, Equatable {
        case advertised
        case fallback
    }
}

/// Builds a validated SSO launch URL for browser-based Moodle authentication.
///
/// Prefers the site-advertised `launchurl` from `tool_mobile_get_public_config`.
/// Falls back to `<baseURL>/admin/tool/mobile/launch.php` when the advertised URL
/// is absent or unusable. Returns a precise error if neither path produces a valid URL.
public enum MoodleSSOLaunchURLBuilder {

    private static let logger = Logger(
        subsystem: "es.amodrono.foodle.networking",
        category: "SSOLaunchURLBuilder"
    )

    private static let requiredKeys: Set<String> = ["service", "passport", "urlscheme"]

    /// Build the final SSO launch URL for the given site.
    ///
    /// - Parameters:
    ///   - site: The Moodle site requiring SSO.
    ///   - passport: The random passport nonce for callback verification.
    ///   - callbackScheme: The URL scheme registered for the SSO callback (default: `foodle`).
    /// - Returns: A build result containing the validated URL and its source.
    /// - Throws: `FoodleError.ssoLaunchURLUnavailable` if no valid URL can be formed.
    public static func build(
        for site: MoodleSite,
        passport: String,
        callbackScheme: String = MoodleSite.callbackScheme
    ) throws -> MoodleSSOLaunchURLBuildResult {
        let requiredQueryItems = [
            URLQueryItem(name: "service", value: "moodle_mobile_app"),
            URLQueryItem(name: "passport", value: passport),
            URLQueryItem(name: "urlscheme", value: callbackScheme),
        ]

        // Try the advertised launch URL first.
        if let advertisedResult = resolveAdvertised(
            rawLaunchURL: site.capabilities.launchURL,
            baseURL: site.baseURL,
            requiredQueryItems: requiredQueryItems
        ) {
            logger.info("Using advertised launch URL for \(site.displayName, privacy: .public)")
            return advertisedResult
        }

        // Fall back to the default Moodle mobile launch endpoint.
        if let fallbackResult = resolveFallback(
            baseURL: site.baseURL,
            requiredQueryItems: requiredQueryItems
        ) {
            logger.info("Using fallback launch URL for \(site.displayName, privacy: .public)")
            return fallbackResult
        }

        logger.error("Could not build any valid SSO launch URL for \(site.displayName, privacy: .public)")
        throw FoodleError.ssoLaunchURLUnavailable(
            detail: "Neither the site-advertised launch URL nor the default endpoint could produce a valid URL."
        )
    }

    // MARK: - Private

    private static func resolveAdvertised(
        rawLaunchURL: String?,
        baseURL: URL,
        requiredQueryItems: [URLQueryItem]
    ) -> MoodleSSOLaunchURLBuildResult? {
        guard let raw = rawLaunchURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            logger.debug("No advertised launch URL present; will use fallback")
            return nil
        }

        // Determine if the raw value is absolute or relative and resolve accordingly.
        let resolvedURL: URL?
        if let absolute = URL(string: raw), absolute.scheme != nil {
            // Absolute URL — use directly.
            resolvedURL = absolute
        } else {
            // Relative URL — resolve against baseURL.
            resolvedURL = URL(string: raw, relativeTo: baseURL)?.absoluteURL
        }

        guard let resolved = resolvedURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: true) else {
            logger.warning("Advertised launch URL could not be parsed: \(raw, privacy: .private)")
            return nil
        }

        mergeQueryItems(into: &components, required: requiredQueryItems)

        guard let finalURL = components.url else {
            logger.warning("Advertised launch URL could not materialize after query merge: \(raw, privacy: .private)")
            return nil
        }

        return MoodleSSOLaunchURLBuildResult(url: finalURL, source: .advertised)
    }

    private static func resolveFallback(
        baseURL: URL,
        requiredQueryItems: [URLQueryItem]
    ) -> MoodleSSOLaunchURLBuildResult? {
        let fallbackURL = baseURL.appendingPathComponent("admin/tool/mobile/launch.php")
        guard var components = URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        mergeQueryItems(into: &components, required: requiredQueryItems)

        guard let finalURL = components.url else {
            return nil
        }

        return MoodleSSOLaunchURLBuildResult(url: finalURL, source: .fallback)
    }

    /// Merge required query items into existing components, replacing any
    /// pre-existing `service`, `passport`, or `urlscheme` entries and
    /// preserving all unrelated items.
    private static func mergeQueryItems(
        into components: inout URLComponents,
        required: [URLQueryItem]
    ) {
        var existing = components.queryItems ?? []

        // Remove any existing entries for the keys we control.
        existing.removeAll { requiredKeys.contains($0.name) }

        // Append our required items.
        existing.append(contentsOf: required)

        components.queryItems = existing
    }
}
