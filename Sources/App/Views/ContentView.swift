// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import WhatsNewKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    // Build the environment once per ContentView instance instead of on every
    // body re-evaluation. Avoids spinning up a fresh UserDefaultsWhatsNewVersionStore
    // and re-constructing the collection on every state change.
    @State private var whatsNewEnvironment = WhatsNewEnvironment(
        versionStore: UserDefaultsWhatsNewVersionStore(),
        whatsNewCollection: WhatsNewProvider.makeCollection()
    )

    var body: some View {
        Group {
            switch appState.currentScreen {
            case .onboarding:
                OnboardingView()
            case .workspace:
                WorkspaceView()
                    .environment(\.whatsNew, whatsNewEnvironment)
                    .whatsNewSheet()
                    .supportPrompt()
            }
        }
    }
}
