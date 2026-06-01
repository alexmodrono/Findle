// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    @AppStorage("lastWhatsNewVersion") private var lastWhatsNewVersion = ""
    @State private var showWhatsNew = false

    var body: some View {
        Group {
            switch appState.currentScreen {
            case .onboarding:
                OnboardingView()
            case .workspace:
                WorkspaceView()
                    .supportPrompt()
                    .sheet(isPresented: $showWhatsNew) {
                        WhatsNewView(release: .current, databasePath: appState.databaseFilePath) {
                            lastWhatsNewVersion = WhatsNewRelease.current.version
                            showWhatsNew = false
                        }
                    }
                    .task { evaluateWhatsNew() }
            }
        }
    }

    private func evaluateWhatsNew() {
        // Show the showcase whenever the user hasn't seen the current release —
        // fresh installs included. The sheet is only attached to the workspace,
        // so onboarding is never interrupted, and `lastWhatsNewVersion` is
        // stamped to the current version when the sheet is dismissed.
        if lastWhatsNewVersion != WhatsNewRelease.current.version {
            showWhatsNew = true
        }
    }
}
