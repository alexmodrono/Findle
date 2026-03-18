// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import WhatsNewKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.currentScreen {
            case .onboarding:
                OnboardingView()
            case .workspace:
                WorkspaceView()
            }
        }
        .environment(
            \.whatsNew,
            WhatsNewEnvironment(
                versionStore: UserDefaultsWhatsNewVersionStore(),
                whatsNewCollection: WhatsNewProvider.collection
            )
        )
        .whatsNewSheet()
    }
}
