import Foundation
import AuthenticationServices
import SharedDomain
import OSLog

/// Manages browser-based SSO authentication using ASWebAuthenticationSession.
/// This is used when Moodle sites require SSO (SAML, OAuth2, CAS, Microsoft, etc.)
/// instead of direct username/password login.
@MainActor
public final class WebAuthSession: NSObject {
    private let logger = Logger(subsystem: "es.amodrono.foodle.networking", category: "WebAuth")

    /// Perform SSO authentication for a Moodle site.
    /// Opens the system browser, lets the user authenticate through their identity provider,
    /// and captures the token callback.
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
        let launchURL = site.ssoLaunchURL(passport: passport)
        let callbackScheme = MoodleSite.callbackScheme

        logger.info("Starting SSO authentication for \(site.displayName, privacy: .public)")
        logger.debug("SSO launch URL: \(launchURL.absoluteString, privacy: .private)")

        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: launchURL,
                callbackURLScheme: callbackScheme
            ) { url, error in
                if let error = error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: FoodleError.cancelled)
                    } else {
                        continuation.resume(throwing: FoodleError.invalidResponse(
                            detail: "SSO authentication failed: \(error.localizedDescription)"
                        ))
                    }
                    return
                }

                guard let url = url else {
                    continuation.resume(throwing: FoodleError.invalidResponse(
                        detail: "No callback URL received from SSO."
                    ))
                    return
                }

                continuation.resume(returning: url)
            }

            session.presentationContextProvider = presentationContext
            session.prefersEphemeralWebBrowserSession = false

            if !session.start() {
                continuation.resume(throwing: FoodleError.internalError(
                    detail: "Could not start SSO authentication session."
                ))
            }
        }

        logger.info("SSO callback received")

        // Parse the token from the callback URL
        let client = MoodleClient()
        let token = try client.parseTokenFromSSOCallback(callbackURL: callbackURL, expectedPassport: passport)

        return (token, passport)
    }

    /// Generate a random passport string for SSO verification.
    private func generatePassport() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
