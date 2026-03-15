// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import AppKit
import FileProvider
import OSLog

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let logger = Logger(subsystem: "es.amodrono.foodle", category: "AppDelegate")
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Findle launched")

        // Watch for main windows opening/closing to toggle Dock icon visibility.
        let willClose = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let noteObject = note.object
            Task { @MainActor in
                guard let window = noteObject as? NSWindow, window.canBecomeMain else { return }
                // Defer one run-loop cycle so the window has time to be removed from the windows array.
                try? await Task.sleep(for: .zero)
                self?.updateActivationPolicy()
            }
        }
        let didBecomeKey = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let noteObject = note.object
            Task { @MainActor in
                guard let window = noteObject as? NSWindow, window.canBecomeMain else { return }
                self?.updateActivationPolicy()
            }
        }

        windowObservers = [willClose, didBecomeKey]
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            // User clicked the Dock icon while no windows were visible — show one.
            NSApp.setActivationPolicy(.regular)
            return true
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        logger.info("Findle terminating")
    }

    /// Switch to accessory (menu-bar-only) mode when no main windows are visible,
    /// and back to regular (Dock icon) mode when a main window is shown.
    @MainActor
    private func updateActivationPolicy() {
        let showMenuBar = UserDefaults.standard.bool(forKey: "showMenuBarIcon")

        let hasVisibleMainWindow = NSApp.windows.contains { window in
            window.canBecomeMain && window.isVisible && !window.isMiniaturized
        }

        let desiredPolicy: NSApplication.ActivationPolicy
        if hasVisibleMainWindow {
            desiredPolicy = .regular
        } else if showMenuBar {
            desiredPolicy = .accessory
        } else {
            // No menu bar icon and no window — stay regular so the Dock icon stays
            desiredPolicy = .regular
        }

        if NSApp.activationPolicy() != desiredPolicy {
            NSApp.setActivationPolicy(desiredPolicy)
        }
    }
}
