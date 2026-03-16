// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
import FileProvider

/// Regression tests for FileProvider concurrency safety.
///
/// FileProvider delivers completion-handler callbacks (signalEnumerator,
/// signalErrorResolved, getUserVisibleURL) on background dispatch queues
/// such as FPM-SignalUpdateQueue — NOT the main thread.
///
/// If these callbacks reach code that expects @MainActor isolation,
/// Swift 6's runtime traps with `dispatch_assert_queue_fail`. This crash
/// only manifests in Release builds, making it invisible during development.
///
/// Prevention strategy:
///   1. All FileProvider callback-based APIs go through `nonisolated` helpers
///      so the continuation never carries a MainActor expectation.
///   2. Signaling is dispatched via `Task.detached` from @MainActor code.
///   3. These tests verify both patterns remain intact.
final class FileProviderConcurrencyTests: XCTestCase {

    // MARK: - Pattern: nonisolated + background callback

    /// A nonisolated function wrapping a completion handler that fires on a
    /// background queue must not crash. This mirrors the pattern used by
    /// `signalResolvedFileProviderError` and `userVisibleFileProviderURL`.
    func testNonisolatedContinuationFromBackgroundQueue() async {
        let result = await simulateBackgroundCallback()
        XCTAssertTrue(result)
    }

    /// Same as above, but called from a @MainActor context.
    /// This is the exact scenario that caused the production crash:
    /// a MainActor-bound caller awaiting a function whose underlying
    /// completion handler fires on a background queue.
    @MainActor
    func testNonisolatedContinuationFromMainActorCaller() async {
        let result = await simulateBackgroundCallback()
        XCTAssertTrue(result)
    }

    // MARK: - Pattern: Task.detached from @MainActor

    /// Verifies that Task.detached actually drops MainActor context.
    /// If someone changes `Task.detached` to `Task` in the signaling code,
    /// this test demonstrates the difference in thread behavior.
    @MainActor
    func testDetachedTaskRunsOffMainThread() async {
        let expectation = expectation(description: "Runs off main thread")
        let state = ThreadCheckState()

        Task.detached {
            state.captureCurrentThread()
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1.0)

        XCTAssertFalse(
            state.wasOnMainThread,
            "Task.detached must run off the main thread — FileProvider callbacks fire on background queues"
        )
    }

    /// End-to-end pattern test: @MainActor code spawns a detached task that
    /// calls a nonisolated function whose callback fires on a background queue.
    /// This is the full mitigation pattern used in AppState.
    @MainActor
    func testFullSignalingPattern() async {
        let expectation = expectation(description: "Signal completes off main")
        let state = ThreadCheckState()

        // Capture the function ref to avoid `Self` inside `Task.detached`,
        // which confuses the region-based isolation checker.
        let callback = simulateBackgroundCallback
        Task.detached {
            let result = await callback()
            state.captureCurrentThread()
            XCTAssertTrue(result)
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertFalse(state.wasOnMainThread)
    }
}

/// Simulates a FileProvider completion-handler API (like signalEnumerator)
/// that calls back on a background dispatch queue. The `nonisolated` keyword
/// is critical — it ensures the continuation carries no actor expectation,
/// making it safe to resume from any queue.
private nonisolated func simulateBackgroundCallback() async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "test.FPM-SignalUpdateQueue").async {
            continuation.resume(returning: true)
        }
    }
}

/// Thread-safe state tracker that captures whether code ran on the main thread.
/// Uses a synchronous method to avoid `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` on
/// `Thread.isMainThread` (macOS 26+).
private final class ThreadCheckState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var wasOnMainThread = true

    func captureCurrentThread() {
        lock.lock()
        defer { lock.unlock() }
        wasOnMainThread = Thread.isMainThread
    }
}
