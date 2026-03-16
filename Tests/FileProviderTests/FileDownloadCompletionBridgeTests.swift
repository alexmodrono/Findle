// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
import FileProvider
@testable import SharedDomain

final class FileDownloadCompletionBridgeTests: XCTestCase {
    func testConcurrentSuccessCallbacksOnlyCompleteOnce() async {
        let progress = Progress(totalUnitCount: 100)
        let completionCalled = expectation(description: "completion called once")

        let state = CallbackState()
        let bridge = FileDownloadCompletionBridge(progress: progress) { url, item, error in
            state.record(url: url, item: item, error: error)
            completionCalled.fulfill()
        }

        let localItem = makeLocalItem()
        let url = URL(fileURLWithPath: "/tmp/findle-test")

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                bridge.succeed(url: url, item: FileProviderItem(localItem: localItem))
            }
            group.addTask {
                bridge.succeed(url: url, item: FileProviderItem(localItem: localItem))
            }
        }

        await fulfillment(of: [completionCalled], timeout: 1.0)

        XCTAssertEqual(state.invocationCount, 1)
        XCTAssertEqual(progress.completedUnitCount, progress.totalUnitCount)
        XCTAssertEqual(state.lastURL, url)
        XCTAssertNil(state.lastError)
    }

    func testFirstFailureWinsAndProgressStaysIncomplete() async {
        let progress = Progress(totalUnitCount: 100)
        let completionCalled = expectation(description: "completion called once")

        let state = CallbackState()
        let bridge = FileDownloadCompletionBridge(progress: progress) { url, item, error in
            state.record(url: url, item: item, error: error)
            completionCalled.fulfill()
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                bridge.fail(TestError.failed)
            }
            group.addTask {
                bridge.fail(TestError.failed)
            }
        }

        await fulfillment(of: [completionCalled], timeout: 1.0)

        XCTAssertEqual(state.invocationCount, 1)
        XCTAssertEqual(progress.completedUnitCount, 0)
        XCTAssertNotNil(state.lastError)
        XCTAssertNil(state.lastURL)
    }

    private func makeLocalItem() -> LocalItem {
        LocalItem(
            id: "item-1",
            siteID: "site-1",
            courseID: 42,
            remoteID: 9,
            filename: "example.pdf",
            contentType: "application/pdf"
        )
    }
}

private enum TestError: Error {
    case failed
}

private final class CallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var invocationCount = 0
    private(set) var lastURL: URL?
    private(set) var lastError: Error?

    func record(url: URL?, item _: NSFileProviderItem?, error: Error?) {
        lock.lock()
        defer { lock.unlock() }

        invocationCount += 1
        lastURL = url
        lastError = error
    }
}
