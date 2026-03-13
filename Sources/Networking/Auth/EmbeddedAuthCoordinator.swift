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
/// Each authentication attempt uses a fresh non-persistent `WKWebsiteDataStore`
/// and a new `WKProcessPool` to avoid leaking session state between attempts.
@MainActor
public final class EmbeddedAuthCoordinator: NSObject {

    private let logger = Logger(subsystem: "es.amodrono.foodle.networking", category: "EmbeddedAuth")

    /// The WKWebView managed by this coordinator. Callers embed this in their view hierarchy.
    public private(set) var webView: WKWebView!

    private var continuation: CheckedContinuation<EmbeddedAuthResult, Error>?
    private var passport: String = ""
    private var site: MoodleSite?

    /// Start the embedded SSO flow and return the resulting auth token.
    ///
    /// - Parameters:
    ///   - site: The Moodle site to authenticate with.
    /// - Returns: The authentication result containing the token and passport.
    /// - Throws: `FoodleError` on failure or cancellation.
    public func authenticate(site: MoodleSite) async throws -> EmbeddedAuthResult {
        self.site = site
        self.passport = generatePassport()

        // Build the launch URL.
        let buildResult = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport)
        let launchURL = buildResult.url

        logger.info("Starting embedded SSO for \(site.displayName, privacy: .public)")
        logger.info("Launch URL source: \(buildResult.source == .advertised ? "advertised" : "fallback", privacy: .public)")

        // Use the default data store and shared process pool. A non-persistent store
        // with a dedicated process pool causes WKWebView to spawn isolated WebContent
        // processes for cross-origin navigations (e.g. Moodle -> Microsoft). Those child
        // processes fail to inherit the app's sandbox profile and crash on system service
        // lookups. The default store shares a single process pool across origins, avoiding
        // this. Session data is cleaned up explicitly after authentication completes.
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView

        let request = URLRequest(url: launchURL)
        webView.load(request)

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
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
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
