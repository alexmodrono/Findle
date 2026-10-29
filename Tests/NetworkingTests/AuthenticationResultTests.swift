import XCTest
@testable import FindleNetworking
import SharedDomain

@MainActor
final class AuthenticationResultTests: XCTestCase {
    func testEarlyCallbackIsDeliveredWhenWaiterArrives() async throws {
        let result = AuthenticationResult<String>()
        result.resolve(.success("token"))
        let token = try await result.wait()
        XCTAssertEqual(token, "token")
    }

    func testEarlyFailureIsDeliveredAndLateSuccessIgnored() async {
        let result = AuthenticationResult<String>()
        result.resolve(.failure(FindleError.cancelled))
        result.resolve(.success("late token"))
        do { _ = try await result.wait(); XCTFail("Late token replaced cancellation") }
        catch { guard case .cancelled = error as? FindleError else { return XCTFail("Expected cancellation") } }
    }

    func testDuplicateCallbacksKeepFirstResult() async throws {
        let result = AuthenticationResult<String>()
        result.resolve(.success("first"))
        result.resolve(.failure(FindleError.cancelled))
        result.resolve(.success("second"))
        let token = try await result.wait()
        XCTAssertEqual(token, "first")
    }

    func testCancellationDoesNotNeedWebKitCallbackOrAffectNextAttempt() async throws {
        let old = AuthenticationResult<String>()
        let next = AuthenticationResult<String>()
        let waiting = expectation(description: "awaiting embedded callback")
        let task = Task { waiting.fulfill(); return try await old.wait() }
        await fulfillment(of: [waiting], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled attempt succeeded") } catch { }
        old.resolve(.success("late old token"))
        next.resolve(.success("new token"))
        let token = try await next.wait()
        XCTAssertEqual(token, "new token")
    }
}
