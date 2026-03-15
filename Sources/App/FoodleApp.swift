// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import CoreSpotlight

@main
struct FoodleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
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
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1220, height: 820)

        Settings {
            SettingsView()
                .environmentObject(appState)
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
