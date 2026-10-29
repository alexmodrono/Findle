// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
// Licensed under the Apache License, Version 2.0.

import Foundation
import SharedDomain

/// One attempt owns its result, including a callback received before a waiter.
/// Keeping this separate from the web view also makes cancellation independent
/// of WebKit's navigation callbacks.
@MainActor
final class AuthenticationResult<Value: Sendable> {
    let id = UUID()
    private var result: Result<Value, Error>?
    private var waiters: [CheckedContinuation<Value, Error>] = []

    func resolve(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(with: result) }
    }

    func wait() async throws -> Value {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if let result { continuation.resume(with: result) }
                else { waiters.append(continuation) }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(.failure(FindleError.cancelled)) }
        }
    }
}
