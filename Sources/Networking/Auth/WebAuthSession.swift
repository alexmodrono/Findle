// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import AuthenticationServices
import SharedDomain
import OSLog

protocol WebAuthenticationSessionProtocol: AnyObject {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)? { get set }
    var prefersEphemeralWebBrowserSession: Bool { get set }
    func start() -> Bool
    func cancel()
}

extension ASWebAuthenticationSession: WebAuthenticationSessionProtocol {}

/// Manages browser-based SSO authentication using ASWebAuthenticationSession.
/// This is used when Moodle sites report `SiteLoginType.browser` (SAML, OAuth2, CAS, etc.)
///
/// For `SiteLoginType.embedded`, use `EmbeddedAuthCoordinator` which presents
/// a `WKWebView` in-app instead of opening the system browser.
@MainActor
public final class WebAuthSession: NSObject {
    private let logger = Logger(subsystem: "es.amodrono.findle.networking", category: "WebAuth")
    typealias SessionFactory = (
        URL,
        String?,
        @escaping (URL?, Error?) -> Void
    ) -> any WebAuthenticationSessionProtocol

    private struct Attempt {
        let id: UUID
        let continuation: CheckedContinuation<URL, Error>
        let session: any WebAuthenticationSessionProtocol
        // ASWebAuthenticationSession holds its presentation context weakly.
        let presentationContext: any ASWebAuthenticationPresentationContextProviding
    }
    private var activeAttempt: Attempt?
    private let sessionFactory: SessionFactory
    private let passportGenerator: () throws -> String

    public override init() {
        self.passportGenerator = { try SSONonce.generate() }
        self.sessionFactory = { url, callbackURLScheme, completionHandler in
            ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackURLScheme,
                completionHandler: completionHandler
            )
        }
        super.init()
    }

    init(passportGenerator: @escaping () throws -> String = { try SSONonce.generate() },
         sessionFactory: @escaping SessionFactory) {
        self.sessionFactory = sessionFactory
        self.passportGenerator = passportGenerator
        super.init()
    }

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
        try Task.checkCancellation()
        cancel()
        let passport = try passportGenerator()
        let callbackScheme = MoodleSite.callbackScheme
        let logger = self.logger

        // Build the launch URL through the dedicated builder.
        let buildResult: MoodleSSOLaunchURLBuildResult
        do {
            buildResult = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)
        } catch {
            logger.error("SSO launch URL build failed for \(site.displayName, privacy: .private): \(DiagnosticFailure(error).summary, privacy: .public)")
            throw error
        }

        let launchURL = buildResult.url

        logger.info("Starting SSO authentication for \(site.displayName, privacy: .private)")
        logger.info("Login type: \(String(describing: site.capabilities.loginType), privacy: .public)")
        logger.info("Launch URL source: \(buildResult.source == .advertised ? "advertised" : "fallback", privacy: .public)")

        let attemptID = UUID()
        let callbackURL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: FindleError.cancelled)
                    return
                }
                // A retry explicitly retires the old waiter, even if the system
                // never invokes its completion handler after cancel().
                let session = sessionFactory(launchURL, callbackScheme) { [weak self] url, error in
                    Task { @MainActor [weak self] in
                        let result: Result<URL, Error>
                        if let error {
                            let nsError = error as NSError
                            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                                result = .failure(FindleError.cancelled)
                            } else {
                                result = .failure(FindleError.ssoCallbackInvalid(
                                    detail: "SSO authentication failed: \(error.localizedDescription)"
                                ))
                            }
                        } else if let url {
                            result = .success(url)
                        } else {
                            result = .failure(FindleError.ssoCallbackInvalid(detail: "No callback URL received from SSO."))
                        }
                        self?.finish(attemptID: attemptID, result: result)
                    }
                }
                session.presentationContextProvider = presentationContext
                session.prefersEphemeralWebBrowserSession = false
                activeAttempt = Attempt(id: attemptID, continuation: continuation,
                                        session: session, presentationContext: presentationContext)
                if !session.start() {
                    finish(attemptID: attemptID, result: .failure(FindleError.ssoSessionStartFailed(
                        detail: "The browser authentication session could not be started for \(site.displayName)."
                    )))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(attemptID: attemptID)
            }
        }
        try Task.checkCancellation()

        // Log high-signal callback metadata without leaking the token payload.
        if let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) {
            let hasToken = components.queryItems?.contains(where: { $0.name == "token" }) == true
                || callbackURL.absoluteString.contains("://token=")
            // In Moodle's scheme://token=payload syntax, the URL host is the
            // credential payload. Do not submit it to logging, even as private.
            logger.info("SSO callback received — scheme: \(components.scheme ?? "<none>", privacy: .private), hasToken: \(hasToken, privacy: .public)")
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

    /// Cancel without depending on a callback from AuthenticationServices.
    public func cancel() {
        guard let id = activeAttempt?.id else { return }
        cancel(attemptID: id)
    }

    private func cancel(attemptID: UUID) {
        guard let attempt = activeAttempt, attempt.id == attemptID else { return }
        activeAttempt = nil
        attempt.session.cancel()
        attempt.continuation.resume(throwing: FindleError.cancelled)
    }

    private func finish(attemptID: UUID, result: Result<URL, Error>) {
        guard let attempt = activeAttempt, attempt.id == attemptID else { return }
        activeAttempt = nil
        attempt.continuation.resume(with: result)
    }

}
