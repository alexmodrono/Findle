import Foundation
import AuthenticationServices
import SharedDomain
import OSLog

/// Manages browser-based SSO authentication using ASWebAuthenticationSession.
/// This is used when Moodle sites report `SiteLoginType.browser` (SAML, OAuth2, CAS, etc.)
///
/// For `SiteLoginType.embedded`, use `EmbeddedAuthCoordinator` which presents
/// a `WKWebView` in-app instead of opening the system browser.
@MainActor
public final class WebAuthSession: NSObject {
    private let logger = Logger(subsystem: "es.amodrono.foodle.networking", category: "WebAuth")

    /// Strong reference to the active session. ASWebAuthenticationSession does not
    /// retain itself — the caller must keep a reference until the callback fires.
    /// Without this, ARC can deallocate the session mid-flow, causing Safari to
    /// show "cannot open the page because the address is invalid."
    private var activeSession: ASWebAuthenticationSession?

    /// ASWebAuthenticationSession keeps a weak reference to its presentation context
    /// provider, so retain it for the full duration of the browser flow.
    private var activePresentationContext: (any ASWebAuthenticationPresentationContextProviding)?

    /// Perform browser-based SSO authentication for a Moodle site.
    /// Opens the system browser via `ASWebAuthenticationSession`, lets the user authenticate
    /// through their identity provider, and captures the token callback.
    ///
    /// This method should be used for `SiteLoginType.browser`. For `.embedded`, use
    /// the `EmbeddedAuthCoordinator` with a `WKWebView` instead.
    ///
    /// - Parameters:
    ///   - site: The Moodle site requiring SSO.
    ///   - presentationContext: The window to anchor the auth session to.
    /// - Returns: The authentication token and the passport used for verification.
    public func authenticate(
        site: MoodleSite,
        presentationContext: ASWebAuthenticationPresentationContextProviding
    ) async throws -> (token: AuthToken, passport: String) {
        let passport = generatePassport()
        let callbackScheme = MoodleSite.callbackScheme
        let logger = self.logger

        // Build the launch URL through the dedicated builder.
        let buildResult: MoodleSSOLaunchURLBuildResult
        do {
            buildResult = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)
        } catch {
            logger.error("SSO launch URL build failed for \(site.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }

        let launchURL = buildResult.url

        logger.info("Starting SSO authentication for \(site.displayName, privacy: .public)")
        logger.info("Login type: \(String(describing: site.capabilities.loginType), privacy: .public)")
        logger.info("Discovered launchurl: \(site.capabilities.launchURL ?? "<none>", privacy: .public)")
        logger.info("Launch URL source: \(buildResult.source == .advertised ? "advertised" : "fallback", privacy: .public)")
        logger.info("Final SSO launch URL: \(launchURL.absoluteString, privacy: .public)")

        let callbackURL: URL
        do {
            callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let completionGate = SessionCompletionGate()
                let session = ASWebAuthenticationSession(
                    url: launchURL,
                    callbackURLScheme: callbackScheme
                ) { [weak self] url, error in
                    guard completionGate.markCompleted() else {
                        logger.error("Ignoring duplicate ASWebAuthenticationSession completion for \(site.displayName, privacy: .public)")
                        return
                    }

                    // Clear the strong reference now that the session has completed.
                    self?.activeSession = nil
                    self?.activePresentationContext = nil

                    if let error = error {
                        let nsError = error as NSError
                        logger.error("SSO authentication session failed for \(site.displayName, privacy: .public) with \(nsError.domain, privacy: .public) (\(nsError.code, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                        if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                            continuation.resume(throwing: FoodleError.cancelled)
                        } else {
                            continuation.resume(throwing: FoodleError.ssoCallbackInvalid(
                                detail: "SSO authentication failed: \(error.localizedDescription)"
                            ))
                        }
                        return
                    }

                    guard let url = url else {
                        continuation.resume(throwing: FoodleError.ssoCallbackInvalid(
                            detail: "No callback URL received from SSO."
                        ))
                        return
                    }

                    continuation.resume(returning: url)
                }

                session.presentationContextProvider = presentationContext
                session.prefersEphemeralWebBrowserSession = false

                self.activePresentationContext = presentationContext
                // Retain the session for the duration of the auth flow.
                self.activeSession = session

                if !session.start() {
                    self.activeSession = nil
                    self.activePresentationContext = nil
                    guard completionGate.markCompleted() else {
                        logger.error("Ignoring duplicate ASWebAuthenticationSession start failure for \(site.displayName, privacy: .public)")
                        return
                    }
                    continuation.resume(throwing: FoodleError.ssoSessionStartFailed(
                        detail: "The browser authentication session could not be started for \(site.displayName)."
                    ))
                }
            }
        } catch {
            activeSession = nil
            activePresentationContext = nil
            throw error
        }

        // Log high-signal callback metadata without leaking the token payload.
        if let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) {
            let hasToken = components.queryItems?.contains(where: { $0.name == "token" }) == true
                || callbackURL.absoluteString.contains("://token=")
            logger.info("SSO callback received — scheme: \(components.scheme ?? "<none>", privacy: .public), host: \(components.host ?? "<none>", privacy: .public), hasToken: \(hasToken, privacy: .public)")
        } else {
            logger.info("SSO callback received")
        }

        // Parse the token from the callback URL string.
        let client = MoodleClient()
        let token = try client.parseTokenFromSSOCallback(
            callbackURLString: callbackURL.absoluteString,
            site: site,
            passport: passport
        )

        return (token, passport)
    }

    /// Generate a random passport string for SSO verification.
    private func generatePassport() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private final class SessionCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var hasCompleted = false

    func markCompleted() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !hasCompleted else {
            return false
        }

        hasCompleted = true
        return true
    }
}
