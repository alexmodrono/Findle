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

    private let logger = Logger(subsystem: "es.amodrono.foodle.networking", category: "EmbeddedAuth")

    /// The WKWebView managed by this coordinator. Callers embed this in their view hierarchy.
    public private(set) var webView: WKWebView!

    private var continuation: CheckedContinuation<EmbeddedAuthResult, Error>?
    private var passport: String = ""
    private var site: MoodleSite?
    private var pendingRequest: URLRequest?
    private var dataStoreIdentifier: UUID?

    /// Configure the embedded web view for SSO authentication without loading the page.
    ///
    /// Call `loadLaunchPage()` after the web view is in the view hierarchy (e.g. from
    /// `.onAppear`), then `waitForResult()` to await the callback.
    ///
    /// - Parameter site: The Moodle site to authenticate with.
    public func configure(site: MoodleSite) throws {
        self.site = site
        self.passport = generatePassport()

        // Build the launch URL.
        let buildResult = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport)
        let launchURL = buildResult.url

        logger.info("Starting embedded SSO for \(site.displayName, privacy: .public)")
        logger.info("Launch URL source: \(buildResult.source == .advertised ? "advertised" : "fallback", privacy: .public)")

        // Create a fresh persistent data store for each SSO attempt so that
        // ITP starts with a clean slate while cookies persist across the
        // redirect chain.
        let storeID = UUID()
        self.dataStoreIdentifier = storeID

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Register all known Moodle/Open LMS callback schemes with the web view.
        let schemeHandler = SSOCallbackSchemeHandler { [weak self] urlString in
            self?.completeWithCallbackURL(urlString)
        }
        for scheme in MoodleSite.acceptedCallbackSchemes {
            config.setURLSchemeHandler(schemeHandler, forURLScheme: scheme)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
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
    public func waitForResult() async throws -> EmbeddedAuthResult {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Cancel the embedded SSO flow.
    public func cancel() {
        webView?.stopLoading()
        cleanUpWebData()
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: FoodleError.cancelled)
    }

    // MARK: - Private

    private func cleanUpWebData() {
        guard let id = dataStoreIdentifier else { return }
        dataStoreIdentifier = nil
        Task {
            try? await WKWebsiteDataStore.remove(forIdentifier: id)
        }
    }

    private func generatePassport() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func completeWithCallbackURL(_ urlString: String) {
        guard let site = site, let pending = continuation else { return }
        continuation = nil
        cleanUpWebData()

        do {
            let client = MoodleClient()
            let token = try client.parseTokenFromSSOCallback(
                callbackURLString: urlString,
                site: site,
                passport: passport
            )
            pending.resume(returning: EmbeddedAuthResult(token: token, passport: passport))
        } catch {
            pending.resume(throwing: error)
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
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let urlString = url.absoluteString

        // Check for a non-HTTP(S) scheme containing "token=" — this is the SSO callback.
        let scheme = url.scheme?.lowercased() ?? ""
        let isHTTP = scheme == "http" || scheme == "https"

        if !isHTTP && urlString.contains("token=") {
            logger.info("Intercepted SSO callback with scheme: \(scheme, privacy: .public)")
            decisionHandler(.cancel)
            completeWithCallbackURL(urlString)
            return
        }

        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let host = webView.url?.host ?? "<unknown>"
        logger.info("Navigation started: \(host, privacy: .public)")
    }

    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        let host = webView.url?.host ?? "<unknown>"
        logger.info("Server redirect to: \(host, privacy: .public)")
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let host = webView.url?.host ?? "<unknown>"
        logger.info("Navigation finished: \(host, privacy: .public)")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if isExpectedNavigationError(nsError) { return }
        logger.error("Navigation failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public) — \(error.localizedDescription, privacy: .public)")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        if isExpectedNavigationError(nsError) { return }

        logger.error("Provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        cleanUpWebData()
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: FoodleError.ssoCallbackInvalid(
            detail: "The embedded sign-in page failed to load: \(error.localizedDescription)"
        ))
    }

    public func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    private func isExpectedNavigationError(_ error: NSError) -> Bool {
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return true }
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return true }
        return false
    }
}

// MARK: - WKUIDelegate

extension EmbeddedAuthCoordinator: WKUIDelegate {

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
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
