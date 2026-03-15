// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import SharedDomain

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isSyncing = false

    var body: some View {
        statusSection

        Divider()

        Button(isSyncing ? "Syncing…" : "Sync Now", action: syncNow)
            .disabled(isSyncing || !isSignedIn)

        Button("Open in Finder", action: openInFinder)
            .disabled(appState.currentSite == nil)

        Divider()

        Button("Open Findle…", action: showMainWindow)
            .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Findle", action: quit)
            .keyboardShortcut("q", modifiers: .command)
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        if !isSignedIn {
            Text("Not signed in")
        } else if let site = appState.currentSite {
            Text(site.displayName)

            switch appState.syncStatus {
            case .syncing:
                Text("Syncing…")
            case .error:
                Text("Sync error")
            default:
                if let date = appState.lastSyncDate {
                    Text("Last synced \(date, format: .relative(presentation: .named))")
                } else {
                    Text("Not yet synced")
                }
            }
        }
    }

    private var isSignedIn: Bool {
        appState.currentScreen != .onboarding
    }

    // MARK: - Actions

    private func syncNow() {
        Task {
            isSyncing = true
            await appState.syncAll()
            isSyncing = false
        }
    }

    private func openInFinder() {
        Task { await appState.openFileProviderInFinder() }
    }

    private func showMainWindow() {
        NSApp.setActivationPolicy(.regular)

        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // Window was closed — tell the WindowGroup to open a new one.
            NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
        }

        NSApp.activate()
    }

    private func quit() {
        NSApp.terminate(nil)
    }
}
