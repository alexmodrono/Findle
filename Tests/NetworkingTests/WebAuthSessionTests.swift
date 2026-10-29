// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
import AuthenticationServices
import Security
@testable import FindleNetworking
@testable import SharedDomain

@MainActor
final class WebAuthSessionTests: XCTestCase {
    func testRandomGenerationFailureNeverStartsAuthentication() async {
        var sessionsCreated = 0
        let session = WebAuthSession(passportGenerator: {
            try SSONonce.generate(fill: { _ in errSecNotAvailable })
        }, sessionFactory: { _, _, _ in
            sessionsCreated += 1
            return FakeWebAuthenticationSession {}
        })
        do {
            _ = try await session.authenticate(site: Self.site, presentationContext: TestPresentationContextProvider())
            XCTFail("Authentication must not use predictable fallback randomness")
        } catch {
            guard case .ssoSessionStartFailed = error as? FindleError else { return XCTFail("Wrong failure") }
        }
        XCTAssertEqual(sessionsCreated, 0)
    }

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

    func testTaskCancellationFinishesWithoutSystemCallback() async {
        let started = expectation(description: "browser started")
        let fake = FakeWebAuthenticationSession { started.fulfill() }
        let session = WebAuthSession { _, _, _ in fake }
        let task = Task { try await session.authenticate(site: Self.site, presentationContext: TestPresentationContextProvider()) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled authentication succeeded") }
        catch { guard case .cancelled = error as? FindleError else { return XCTFail("Expected cancellation") } }
        XCTAssertEqual(fake.cancelCount, 1)
    }

    func testRetryRetiresOldWaiterAndIgnoresItsLateCallback() async throws {
        let firstStarted = expectation(description: "first browser started")
        let secondStarted = expectation(description: "retry browser started")
        var callbacks: [() -> Void] = []
        var fakes: [FakeWebAuthenticationSession] = []
        let session = WebAuthSession { launchURL, scheme, completion in
            let index = callbacks.count
            let callback = Self.buildCallback(scheme: scheme!, siteURL: Self.site.baseURL.absoluteString,
                                              passport: Self.queryValue("passport", in: launchURL), token: "token-\(index)")
            callbacks.append { completion(URL(string: callback), nil) }
            let fake = FakeWebAuthenticationSession { (index == 0 ? firstStarted : secondStarted).fulfill() }
            fakes.append(fake)
            return fake
        }
        let first = Task { try await session.authenticate(site: Self.site, presentationContext: TestPresentationContextProvider()) }
        await fulfillment(of: [firstStarted], timeout: 1)
        let second = Task { try await session.authenticate(site: Self.site, presentationContext: TestPresentationContextProvider()) }
        await fulfillment(of: [secondStarted], timeout: 1)
        do { _ = try await first.value; XCTFail("Old attempt survived retry") }
        catch { guard case .cancelled = error as? FindleError else { return XCTFail("Expected cancellation") } }
        // Both callbacks are queued through the actual off-actor bridge.
        callbacks[0]()
        callbacks[1]()
        let result = try await second.value
        XCTAssertEqual(result.token.token, "token-1")
        XCTAssertEqual(fakes[0].cancelCount, 1)
        XCTAssertEqual(fakes[1].cancelCount, 0)
    }

    func testStartFailureFinishesOnceDespiteLateCallback() async {
        var callback: ((URL?, Error?) -> Void)?
        let fake = FakeWebAuthenticationSession {}
        fake.startResult = false
        let session = WebAuthSession { _, _, completion in callback = completion; return fake }
        do {
            _ = try await session.authenticate(site: Self.site, presentationContext: TestPresentationContextProvider())
            XCTFail("Failed browser launch succeeded")
        } catch {
            guard case .ssoSessionStartFailed = error as? FindleError else { return XCTFail("Wrong failure: \(error)") }
        }
        callback?(nil, nil)
        session.cancel()
    }

    func testMissingCallbackURLFailsClearly() async {
        let session = WebAuthSession { _, _, completion in
            FakeWebAuthenticationSession { completion(nil, nil) }
        }
        do {
            _ = try await session.authenticate(site: Self.site, presentationContext: TestPresentationContextProvider())
            XCTFail("Missing callback accepted")
        } catch {
            guard case .ssoCallbackInvalid = error as? FindleError else { return XCTFail("Wrong failure: \(error)") }
        }
    }

    private static var site: MoodleSite {
        MoodleSite(displayName: "Example", baseURL: URL(string: "https://moodle.example.edu")!,
                   capabilities: SiteCapabilities(loginType: .browser))
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

    var startResult = true
    private(set) var cancelCount = 0
    private let onStart: () -> Void

    init(onStart: @escaping () -> Void) {
        self.onStart = onStart
    }

    func start() -> Bool {
        onStart()
        return startResult
    }

    func cancel() { cancelCount += 1 }
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
