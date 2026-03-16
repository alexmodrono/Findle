// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
import AuthenticationServices
@testable import FoodleNetworking
@testable import SharedDomain

@MainActor
final class WebAuthSessionTests: XCTestCase {
    func testAuthenticateSucceedsWhenCallbackArrivesOffMainActor() async throws {
        let token = "token-123"
        let site = MoodleSite(
            displayName: "Example",
            baseURL: URL(string: "https://moodle.example.edu")!,
            capabilities: SiteCapabilities(loginType: .browser)
        )
        let presentationContext = TestPresentationContextProvider()

        let session = WebAuthSession { launchURL, callbackURLScheme, completionHandler in
            let callbackBridge = TestSessionCompletionHandler(completionHandler)
            return FakeWebAuthenticationSession {
                DispatchQueue.global().async {
                    let passport = Self.queryValue("passport", in: launchURL)
                    let callback = Self.buildCallback(
                        scheme: callbackURLScheme ?? MoodleSite.callbackScheme,
                        siteURL: site.baseURL.absoluteString,
                        passport: passport,
                        token: token
                    )
                    callbackBridge.call(url: URL(string: callback), error: nil)
                }
            }
        }

        let result = try await session.authenticate(site: site, presentationContext: presentationContext)

        XCTAssertEqual(result.token.token, token)
    }

    func testAuthenticateIgnoresDuplicateBackgroundCallbacks() async throws {
        let token = "token-456"
        let site = MoodleSite(
            displayName: "Example",
            baseURL: URL(string: "https://moodle.example.edu")!,
            capabilities: SiteCapabilities(loginType: .browser)
        )
        let presentationContext = TestPresentationContextProvider()
        let callbacksFinished = expectation(description: "duplicate callbacks finished")

        let session = WebAuthSession { launchURL, callbackURLScheme, completionHandler in
            let callbackBridge = TestSessionCompletionHandler(completionHandler)
            return FakeWebAuthenticationSession {
                let passport = Self.queryValue("passport", in: launchURL)
                let callback = Self.buildCallback(
                    scheme: callbackURLScheme ?? MoodleSite.callbackScheme,
                    siteURL: site.baseURL.absoluteString,
                    passport: passport,
                    token: token
                )

                DispatchQueue.global().async {
                    callbackBridge.call(url: URL(string: callback), error: nil)
                    callbackBridge.call(url: URL(string: callback), error: nil)
                    callbacksFinished.fulfill()
                }
            }
        }

        let result = try await session.authenticate(site: site, presentationContext: presentationContext)
        XCTAssertEqual(result.token.token, token)
        await fulfillment(of: [callbacksFinished], timeout: 1.0)
    }

    nonisolated private static func buildCallback(
        scheme: String,
        siteURL: String,
        passport: String,
        token: String
    ) -> String {
        let signature = MoodleClient.md5("\(siteURL)\(passport)")
        let payload = "\(signature):::\(token)"
        let base64 = Data(payload.utf8).base64EncodedString()
        return "\(scheme)://token=\(base64)"
    }

    nonisolated private static func queryValue(_ name: String, in url: URL) -> String {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value ?? ""
    }
}

private final class FakeWebAuthenticationSession: WebAuthenticationSessionProtocol {
    var presentationContextProvider: (any ASWebAuthenticationPresentationContextProviding)?
    var prefersEphemeralWebBrowserSession = false

    private let onStart: () -> Void

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
    }

    func start() -> Bool {
        onStart()
        return true
    }

    func cancel() {}
}

private final class TestPresentationContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

private final class TestSessionCompletionHandler: @unchecked Sendable {
    private let completionHandler: (URL?, Error?) -> Void

    init(_ completionHandler: @escaping (URL?, Error?) -> Void) {
        self.completionHandler = completionHandler
    }

    func call(url: URL?, error: Error?) {
        completionHandler(url, error)
    }
}
