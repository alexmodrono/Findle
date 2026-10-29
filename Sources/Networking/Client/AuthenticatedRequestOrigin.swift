import Foundation
import Synchronization
import SharedDomain

/// Credentials belong to the selected site's HTTPS origin, including its port.
/// Server-provided file URLs and capability aliases do not extend this trust.
/// Cross-origin CDN downloads deliberately fail closed until the server offers
/// a separately authenticated, credential-free download URL contract.
public struct AuthenticatedRequestOrigin: Sendable {
    private let host: String
    private let port: Int

    public init(site: MoodleSite) throws {
        (host, port) = try Self.origin(of: site.baseURL)
    }

    public func validate(_ url: URL) throws {
        let candidate = try Self.origin(of: url)
        guard candidate.0 == host, candidate.1 == port else {
            throw AuthenticatedRequestError.untrustedDestination
        }
        let credentialNames: Set<String> = ["token", "wstoken", "privatetoken"]
        guard URLComponents(url: url, resolvingAgainstBaseURL: true)?.queryItems?.contains(where: {
            credentialNames.contains($0.name.lowercased())
        }) != true else { throw AuthenticatedRequestError.untrustedDestination }
    }

    public func fileRequest(url: URL, token: AuthToken) throws -> URLRequest {
        try validate(url)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let encoded = token.token.addingPercentEncoding(withAllowedCharacters: allowed)!
        request.httpBody = Data("token=\(encoded)".utf8)
        return request
    }

    private static func origin(of url: URL) throws -> (String, Int) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              (1...65535).contains(components.port ?? 443) else {
            throw AuthenticatedRequestError.untrustedDestination
        }
        return (host, components.port ?? 443)
    }
}

public enum AuthenticatedRequestError: Error, Sendable, LocalizedError {
    case untrustedDestination
    case unsupportedBackgroundSession

    public var errorDescription: String? {
        switch self {
        case .untrustedDestination:
            "Findle cannot send your credentials to this address. Check the Moodle server address."
        case .unsupportedBackgroundSession:
            "Findle cannot make this request securely."
        }
    }
}

/// Task-scoped delegate with immutable trust and a locked terminal rejection.
/// URLSession retains it while the task runs;
/// it owns neither the session nor the task, so cancellation needs no extra task
/// or continuation. Default/ephemeral sessions honor this redirect callback.
public final class AuthenticatedRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let origin: AuthenticatedRequestOrigin
    private let rejected = Mutex(false)

    public var didRejectRedirect: Bool { rejected.withLock { $0 } }

    public func checkRedirect() throws {
        if didRejectRedirect { throw AuthenticatedRequestError.untrustedDestination }
    }

    public init(origin: AuthenticatedRequestOrigin) {
        self.origin = origin
    }

    public func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let url = request.url, (try? origin.validate(url)) != nil else {
            rejected.withLock { $0 = true }
            completionHandler(nil)
            // Refusal otherwise continues receiving the original 30x body.
            // End it now; callers distinguish this from user cancellation and
            // transient network errors rather than retrying credentials.
            task.cancel()
            return
        }
        // Preserve Foundation's method/body semantics for same-origin 30x.
        completionHandler(request)
    }
}
