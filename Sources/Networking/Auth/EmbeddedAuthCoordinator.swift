// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import WebKit
import SharedDomain
import OSLog

/// Result of an embedded SSO authentication attempt.
public struct EmbeddedAuthResult: Sendable {
    public let token: AuthToken
    public let passport: String
}

/// Coordinates embedded SSO authentication using a WKWebView.
///
/// Used when a Moodle site reports `SiteLoginType.embedded` (typeoflogin=3).
/// The web view loads the SSO launch URL and intercepts the redirect back to
/// a custom callback scheme containing the token payload.
@MainActor
public final class EmbeddedAuthCoordinator: NSObject {

    private let logger = Logger(subsystem: "es.amodrono.findle.networking", category: "EmbeddedAuth")

    /// The WKWebView managed by this coordinator. Callers embed this in their view hierarchy.
    public private(set) var webView: WKWebView!

    private var attempt: AuthenticationResult<EmbeddedAuthResult>?
    private var passport: String = ""
    private var site: MoodleSite?
    private var pendingRequest: URLRequest?
    private var attemptFinished = true
    private let cleanup: EmbeddedWebDataStoreCleanup
    private let storeFactory: @MainActor (UUID) -> WKWebsiteDataStore
    private let passportGenerator: @MainActor () throws -> String

    public override init() {
        cleanup = .shared
        storeFactory = { WKWebsiteDataStore(forIdentifier: $0) }
        passportGenerator = { try SSONonce.generate() }
        super.init()
    }

    init(cleanup: EmbeddedWebDataStoreCleanup,
         storeFactory: @escaping @MainActor (UUID) -> WKWebsiteDataStore,
         passportGenerator: @escaping @MainActor () throws -> String = { try SSONonce.generate() }) {
        self.cleanup = cleanup
        self.storeFactory = storeFactory
        self.passportGenerator = passportGenerator
        super.init()
    }

    /// Resume interrupted cleanup once when the host starts. Live attempts are
    /// still protected if a caller invokes this again after startup.
    public static func resumePendingCleanup() {
        EmbeddedWebDataStoreCleanup.shared.retryPending(maximum: 32)
    }

    /// Configure the embedded web view for SSO authentication without loading the page.
    ///
    /// Call `loadLaunchPage()` after the web view is in the view hierarchy (e.g. from
    /// `.onAppear`), then `waitForResult()` to await the callback.
    ///
    /// - Parameter site: The Moodle site to authenticate with.
    public func configure(site: MoodleSite) throws {
        cancel()
        attempt = nil
        self.site = site
        self.passport = try passportGenerator()

        // Build the launch URL.
        let buildResult = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport)
        let launchURL = buildResult.url
        cleanup.retryPending()
        let storeID = try cleanup.registerAttempt()
        let attempt = AuthenticationResult<EmbeddedAuthResult>()
        self.attempt = attempt
        attemptFinished = false

        logger.info("Starting embedded SSO for \(site.displayName, privacy: .private)")
        logger.info("Launch URL source: \(buildResult.source == .advertised ? "advertised" : "fallback", privacy: .public)")

        // Create a fresh persistent data store for each SSO attempt so that
        // ITP starts with a clean slate while cookies persist across the
        // redirect chain.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = storeFactory(storeID)
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Register all known Moodle/Open LMS callback schemes with the web view.
        let attemptID = attempt.id
        let schemeHandler = SSOCallbackSchemeHandler { [weak self] urlString in
            self?.completeWithCallbackURL(urlString, attemptID: attemptID)
        }
        for scheme in MoodleSite.acceptedCallbackSchemes {
            config.setURLSchemeHandler(schemeHandler, forURLScheme: scheme)
        }

        let webView = EmbeddedAuthenticationWebView(configuration: config, storeIdentifier: storeID, cleanup: cleanup)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        // Store the request; it will be loaded once the web view is in the view hierarchy.
        self.pendingRequest = URLRequest(url: launchURL)
    }

    /// Load the SSO launch page in the web view.
    ///
    /// Call this after the web view is in the view hierarchy (e.g. from `.onAppear`).
    public func loadLaunchPage() {
        guard let webView, let request = pendingRequest else { return }
        pendingRequest = nil
        webView.load(request)
    }

    /// Start the embedded SSO flow and return the resulting auth token.
    ///
    /// This is a convenience that configures the web view, loads the page immediately,
    /// and waits for the result. Prefer the two-step `configure(site:)` +
    /// `loadLaunchPage()` flow when the web view must be in the view hierarchy first.
    public func authenticate(site: MoodleSite) async throws -> EmbeddedAuthResult {
        try configure(site: site)
        loadLaunchPage()
        return try await waitForResult()
    }

    /// Wait for the embedded SSO callback.
    ///
    /// Cancelling the calling task cancels the flow, so the continuation is always resumed.
    public func waitForResult() async throws -> EmbeddedAuthResult {
        guard let attempt else { throw FindleError.cancelled }
        return try await withTaskCancellationHandler {
            let value = try await attempt.wait()
            try Task.checkCancellation()
            return value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(attemptID: attempt.id)
            }
        }
    }

    /// Cancel this attempt even when WebKit never produces a navigation callback.
    public func cancel() {
        guard let id = attempt?.id else { return }
        cancel(attemptID: id)
    }

    private func cancel(attemptID: UUID) {
        guard attempt?.id == attemptID else { return }
        finish(.failure(FindleError.cancelled))
    }

    // MARK: - Private

    private func finish(_ result: Result<EmbeddedAuthResult, Error>) {
        guard let attempt, !attemptFinished else { return }
        attemptFinished = true
        pendingRequest = nil
        let view = webView
        webView = nil
        view?.stopLoading()
        view?.navigationDelegate = nil
        view?.uiDelegate = nil
        view?.removeFromSuperview()
        // A caller may still retain the view. Its persistent store stays live
        // until EmbeddedAuthenticationWebView's actual deallocation.
        attempt.resolve(result)
    }

    private func completeWithCallbackURL(_ urlString: String, attemptID: UUID? = nil) {
        guard let site, let attempt, !attemptFinished,
              attemptID == nil || attemptID == attempt.id else { return }
        do {
            let token = try MoodleClient().parseTokenFromSSOCallback(
                callbackURLString: urlString, site: site, passport: passport
            )
            finish(.success(EmbeddedAuthResult(token: token, passport: passport)))
        } catch {
            finish(.failure(error))
        }
    }

}

// MARK: - WKNavigationDelegate

extension EmbeddedAuthCoordinator: WKNavigationDelegate {

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        guard webView === self.webView else { decisionHandler(.cancel); return }
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let urlString = url.absoluteString

        // Check for a non-HTTP(S) scheme containing "token=" — this is the SSO callback.
        let scheme = url.scheme?.lowercased() ?? ""
        let isHTTP = scheme == "http" || scheme == "https"

        if !isHTTP && urlString.contains("token=") {
            logger.info("Intercepted SSO callback")
            decisionHandler(.cancel)
            completeWithCallbackURL(urlString)
            return
        }

        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        let nsError = error as NSError
        if isExpectedNavigationError(nsError) { return }
        logger.error("Navigation failed: \(DiagnosticFailure(error).summary, privacy: .public)")
        finish(.failure(FindleError.ssoCallbackInvalid(
            detail: "The sign-in page failed. Try signing in again."
        )))
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        let nsError = error as NSError
        if isExpectedNavigationError(nsError) { return }

        logger.error("Provisional navigation failed: \(DiagnosticFailure(error).summary, privacy: .public)")
        finish(.failure(FindleError.ssoCallbackInvalid(
            detail: "The sign-in page could not load. Check your connection and try again."
        )))
    }

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        finish(.failure(FindleError.ssoCallbackInvalid(
            detail: "The sign-in page stopped. Try signing in again."
        )))
    }

    private func isExpectedNavigationError(_ error: NSError) -> Bool {
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return true }
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return true }
        return false
    }
}

// MARK: - WKUIDelegate

extension EmbeddedAuthCoordinator: WKUIDelegate {

    public func webViewDidClose(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        finish(.failure(FindleError.cancelled))
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard webView === self.webView else { return nil }
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false {
            if let url = navigationAction.request.url {
                let urlString = url.absoluteString
                let scheme = url.scheme?.lowercased() ?? ""
                let isHTTP = scheme == "http" || scheme == "https"

                if !isHTTP && urlString.contains("token=") {
                    completeWithCallbackURL(urlString)
                    return nil
                }

                webView.load(navigationAction.request)
            }
        }
        return nil
    }
}

// MARK: - WKURLSchemeHandler

private final class SSOCallbackSchemeHandler: NSObject, WKURLSchemeHandler {
    private let onCallback: @MainActor (String) -> Void

    init(onCallback: @escaping @MainActor (String) -> Void) {
        self.onCallback = onCallback
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let urlString = urlSchemeTask.request.url?.absoluteString ?? ""

        if urlString.contains("token=") {
            let callback = onCallback
            Task { @MainActor in
                callback(urlString)
            }
        }

        urlSchemeTask.didFailWithError(URLError(.cancelled))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
