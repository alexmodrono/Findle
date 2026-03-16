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
/// The web view loads the SSO launch URL and intercepts the redirect to a
/// non-HTTP(S) scheme containing the token callback.
///
/// Each authentication attempt cleans up the shared/default website data store
/// after completion or cancellation to avoid persisting SSO session state.
@MainActor
public final class EmbeddedAuthCoordinator: NSObject {

    private let logger = Logger(subsystem: "es.amodrono.foodle.networking", category: "EmbeddedAuth")

    /// The WKWebView managed by this coordinator. Callers embed this in their view hierarchy.
    public private(set) var webView: WKWebView!

    private var continuation: CheckedContinuation<EmbeddedAuthResult, Error>?
    private var passport: String = ""
    private var site: MoodleSite?
    private var pendingRequest: URLRequest?

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

        // Use the shared/default store and process pool so cross-origin SSO
        // redirects stay inside WebKit's normal process model. A non-persistent
        // store paired with a fresh process pool causes extra sandboxed
        // WebContent processes to spin up and emit launchservicesd/RunningBoard
        // warnings on macOS during Microsoft/Google SSO hops.
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        // Register all known Moodle/Open LMS callback schemes with the web view.
        // Without this, WKWebView passes unknown schemes to the system URL handler
        // (showing "no application set to open the URL") instead of routing them
        // through the navigation delegate where we intercept the token callback.
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
    /// In sandboxed, notarized release builds, WebKit's networking process requires
    /// the web view to be in a valid window hierarchy before cross-origin SSO
    /// redirects (e.g. Moodle → Microsoft 365) work reliably.
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
    ///
    /// - Parameters:
    ///   - site: The Moodle site to authenticate with.
    /// - Returns: The authentication result containing the token and passport.
    /// - Throws: `FoodleError` on failure or cancellation.
    public func authenticate(site: MoodleSite) async throws -> EmbeddedAuthResult {
        try configure(site: site)
        loadLaunchPage()
        return try await waitForResult()
    }

    /// Wait for the embedded SSO callback after `prepareAuthentication(site:)`.
    public func waitForResult() async throws -> EmbeddedAuthResult {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    /// Cancel the embedded SSO flow. Returns the user to the SSO step without crashing.
    public func cancel() {
        webView?.stopLoading()
        cleanUpWebData()
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: FoodleError.cancelled)
    }

    /// Remove session cookies and website data left by the SSO flow.
    private func cleanUpWebData() {
        let dataStore = webView?.configuration.websiteDataStore ?? .default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        dataStore.fetchDataRecords(ofTypes: dataTypes) { records in
            dataStore.removeData(ofTypes: dataTypes, for: records) {}
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

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // WebKitErrorFrameLoadInterruptedByPolicyChange (102) is expected when we cancel navigation.
        // NSURLErrorCancelled (-999) fires when a redirect replaces the current navigation.
        if isExpectedNavigationError(nsError) {
            return
        }
        logger.error("Embedded SSO navigation failed: \(error.localizedDescription, privacy: .public)")
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let nsError = error as NSError
        // Redirects (e.g. Moodle -> Microsoft SSO) cancel the old provisional navigation
        // with -999. This is normal and not a real failure.
        if isExpectedNavigationError(nsError) {
            return
        }
        logger.error("Embedded SSO provisional navigation failed: \(error.localizedDescription, privacy: .public)")
        cleanUpWebData()
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: FoodleError.ssoCallbackInvalid(
            detail: "The embedded sign-in page failed to load: \(error.localizedDescription)"
        ))
    }

    /// Errors that are expected during normal SSO redirect chains and should be silently ignored.
    private func isExpectedNavigationError(_ error: NSError) -> Bool {
        // WebKitErrorFrameLoadInterruptedByPolicyChange — we cancelled via decidePolicyFor.
        if error.domain == "WebKitErrorDomain" && error.code == 102 {
            return true
        }
        // NSURLErrorCancelled — a redirect replaced the current navigation.
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
            return true
        }
        return false
    }
}

// MARK: - WKUIDelegate

extension EmbeddedAuthCoordinator: WKUIDelegate {

    /// Handle `window.open()` and `target="_blank"` links by loading them in the
    /// existing web view instead of silently dropping them.
    ///
    /// Identity provider buttons on Moodle login pages (e.g. "Login with Microsoft")
    /// typically use popup navigation. Without this, WKWebView ignores the click entirely.
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // If the navigation target is not the main frame (i.e. it's a popup),
        // load the request in the current web view instead of opening a new one.
        if navigationAction.targetFrame == nil || navigationAction.targetFrame?.isMainFrame == false {
            if let url = navigationAction.request.url {
                logger.info("Handling popup navigation in-place: \(url.host ?? "", privacy: .public)")

                // Check if this is actually the SSO callback before loading.
                let urlString = url.absoluteString
                let scheme = url.scheme?.lowercased() ?? ""
                let isHTTP = scheme == "http" || scheme == "https"

                if !isHTTP && urlString.contains("token=") {
                    logger.info("Intercepted SSO callback from popup with scheme: \(scheme, privacy: .public)")
                    completeWithCallbackURL(urlString)
                    return nil
                }

                webView.load(navigationAction.request)
            }
        }
        // Return nil to prevent creating a new web view.
        return nil
    }
}

// MARK: - WKURLSchemeHandler

/// URL scheme handler that intercepts Moodle SSO callback schemes.
///
/// When registered with `WKWebViewConfiguration.setURLSchemeHandler(_:forURLScheme:)`,
/// this prevents WKWebView from passing custom-scheme URLs (like `ltgopenlmsapp://`,
/// `moodlemobile://`, etc.) to the macOS system URL handler.
///
/// When a registered scheme is loaded, the handler checks for a token callback
/// and notifies the coordinator directly. This is necessary because registered
/// scheme handlers receive the request *instead of* the navigation delegate's
/// `decidePolicyFor` — so the navigation delegate alone cannot intercept them.
private final class SSOCallbackSchemeHandler: NSObject, WKURLSchemeHandler {
    private let onCallback: @MainActor (String) -> Void

    init(onCallback: @escaping @MainActor (String) -> Void) {
        self.onCallback = onCallback
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let urlString = urlSchemeTask.request.url?.absoluteString ?? ""

        if urlString.contains("token=") {
            // Notify the coordinator on the main actor, then fail the task
            // so WKWebView doesn't hang waiting for a response.
            let callback = onCallback
            Task { @MainActor in
                callback(urlString)
            }
        }

        urlSchemeTask.didFailWithError(URLError(.cancelled))
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // Nothing to clean up.
    }
}
