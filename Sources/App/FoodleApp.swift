// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import CoreSpotlight
import Sparkle
import OSLog

private let logger = Logger(subsystem: "es.amodrono.foodle", category: "App")

@main
struct FoodleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var updateController = UpdateController()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 980, minHeight: 680)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    appState.resolveFileProviderAuthIfNeeded()
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    appState.handleSpotlightActivity(activity)
                }
                .onOpenURL { url in
                    // Consume SSO callback URLs (findle://token=…) that arrive
                    // after relaunch.  In-flight SSO sessions handle the callback
                    // themselves; stale URLs delivered on a cold start can be
                    // safely ignored.  Without this handler NSDocumentController
                    // intercepts the URL and shows "No document could be created."
                    logger.info("Ignoring stale URL on launch: \(url.scheme ?? "nil", privacy: .public)")
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1220, height: 820)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(updateController)
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(appState)
        } label: {
            Image(.menuBarIcon)
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)
    }
}
