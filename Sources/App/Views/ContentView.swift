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
                            lastWhatsNewVersion = currentBuildIdentifier
                            showWhatsNew = false
                        }
                    }
                    .task { evaluateWhatsNew() }
            }
        }
    }

    private func evaluateWhatsNew() {
        // Show the showcase whenever the user hasn't seen the current build —
        // fresh installs included, and every new build of the same marketing
        // version (e.g. 0.2.0 (19) → 0.2.0 (20)). The sheet is only attached to
        // the workspace, so onboarding is never interrupted, and
        // `lastWhatsNewVersion` is stamped to the current build on dismiss.
        if lastWhatsNewVersion != currentBuildIdentifier {
            showWhatsNew = true
        }
    }

    /// Short version plus build number, e.g. "0.2.0 (20)". Keying the showcase
    /// off this — rather than the marketing version alone — means each new build
    /// surfaces it, which is what re-cut releases (same version, new build) need.
    private var currentBuildIdentifier: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }
}
