// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// A payload-free notification that crosses process and sandbox boundaries.
///
/// The File Provider extension runs in its own XPC-hosted sandbox and shares no
/// notification center with the app. Darwin notifications are the one channel
/// that works in both directions without extra entitlements or a shared
/// container, at the cost of carrying no user info — receivers must derive any
/// state they need from the database.
public enum DarwinNotification {

    /// Keeps an observer registered for as long as the token is retained.
    public final class Token {
        private let name: String
        private let id: UUID

        init(name: String, id: UUID) {
            self.name = name
            self.id = id
        }

        deinit {
            DarwinNotification.removeObserver(name: name, id: id)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: [UUID: @Sendable () -> Void]] = [:]

    /// Post `name` to every process listening for it, including this one.
    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }

    /// Invoke `handler` whenever `name` is posted by any process.
    ///
    /// The handler runs on an arbitrary thread — hop to the isolation you need.
    /// Observation stops when the returned token is released, so callers must
    /// retain it.
    public static func addObserver(
        for name: String,
        handler: @escaping @Sendable () -> Void
    ) -> Token {
        let id = UUID()

        lock.lock()
        let isFirstForName = handlers[name] == nil
        handlers[name, default: [:]][id] = handler
        lock.unlock()

        // CFNotificationCenter keeps its own registration per (observer, name)
        // pair, so register with the Darwin center only once per name and fan
        // out to the individual handlers ourselves.
        if isFirstForName {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                nil,
                darwinNotificationCallback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }

        return Token(name: name, id: id)
    }

    fileprivate static func dispatch(_ name: String) {
        lock.lock()
        let matching = handlers[name]?.values.map { $0 } ?? []
        lock.unlock()

        for handler in matching {
            handler()
        }
    }

    fileprivate static func removeObserver(name: String, id: UUID) {
        lock.lock()
        handlers[name]?.removeValue(forKey: id)
        let isEmpty = handlers[name]?.isEmpty ?? true
        if isEmpty {
            handlers.removeValue(forKey: name)
        }
        lock.unlock()

        guard isEmpty else { return }
        CFNotificationCenterRemoveObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            nil,
            CFNotificationName(name as CFString),
            nil
        )
    }
}

/// Trampoline from the C callback back into `DarwinNotification`. It cannot
/// capture context, so the posted name is the only routing information
/// available — which is why registration is keyed by name.
private func darwinNotificationCallback(
    center: CFNotificationCenter?,
    observer: UnsafeMutableRawPointer?,
    name: CFNotificationName?,
    object: UnsafeRawPointer?,
    userInfo: CFDictionary?
) {
    guard let name else { return }
    DarwinNotification.dispatch(name.rawValue as String)
}
