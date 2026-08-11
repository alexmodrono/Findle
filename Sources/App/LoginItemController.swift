// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import ServiceManagement
import OSLog

/// Wraps `SMAppService.mainApp` so the Settings "Launch at login" toggle
/// actually registers the app as a login item instead of just toggling a
/// UserDefaults bool that nothing reads.
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var lastError: String?

    private let logger = Logger(subsystem: "es.amodrono.findle", category: "LoginItem")

    init() {
        refresh()
    }

    /// Re-read the actual SMAppService state so the UI reflects reality.
    func refresh() {
        // The system can decide to disable login items behind our back
        // (System Settings > General > Login Items), so the source of
        // truth is SMAppService.mainApp.status, not anything we cached.
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Attempt to register or unregister the app as a login item. Reflects
    /// the actual resulting state back into `isEnabled` so the UI doesn't
    /// show "on" when the system rejected the registration.
    func setEnabled(_ desired: Bool) {
        lastError = nil
        do {
            if desired {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("SMAppService \(desired ? "register" : "unregister") failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }
}
