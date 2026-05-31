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
        if lastWhatsNewVersion.isEmpty {
            // Fresh install — record the version without showing the sheet.
            lastWhatsNewVersion = WhatsNewRelease.current.version
        } else if lastWhatsNewVersion != WhatsNewRelease.current.version {
            showWhatsNew = true
        }
    }
}
