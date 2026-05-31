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
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(appState)
                .environmentObject(updateController)
                .frame(minWidth: 980, minHeight: 680)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    appState.resolveFileProviderAuthIfNeeded()
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    appState.handleSpotlightActivity(activity)
                }
                .onOpenURL { url in
                    // findle://sync[?course=<id>] — the MCP server's broker asks
                    // the app (which holds the token) to pull fresh content.
                    if url.host == "sync" {
                        let courseID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first { $0.name == "course" }?.value
                            .flatMap(Int.init)
                        Task {
                            if appState.courses.isEmpty { await appState.loadCourses() }
                            if let courseID, let course = appState.courses.first(where: { $0.id == courseID }) {
                                await appState.syncCourse(course)
                            } else {
                                await appState.syncAll()
                            }
                        }
                        return
                    }
                    // Consume SSO callback URLs (findle://token=…) that arrive
                    // after relaunch.  In-flight SSO sessions handle the callback
                    // themselves; stale URLs delivered on a cold start can be
                    // safely ignored.  Without this handler NSDocumentController
                    // intercepts the URL and shows "No document could be created."
                    logger.info("Ignoring stale URL on launch: \(url.scheme ?? "nil", privacy: .public)")
                }
        }
        // Airlock's onboarding makes the window transparent and hides the
        // traffic-light buttons, but the title bar itself stays put unless the
        // window has no titled chrome — otherwise the bar and app title float
        // over the intro card. `.hiddenTitleBar` is the configuration Airlock
        // documents; the workspace's toolbar still renders in the title area.
        .windowStyle(.hiddenTitleBar)
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
