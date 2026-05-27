// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI

/// Occasional prompt asking users to support the project.
struct SupportPrompt: ViewModifier {
    private static let launchCountKey = "supportPromptLaunchCount"
    private static let lastShownLaunchKey = "supportPromptLastShownLaunch"
    private static let minLaunches = 5
    private static let minLaunchesBetweenPrompts = 10
    private static let showProbability = 0.3

    @AppStorage(SupportPrompt.launchCountKey) private var launchCount = 0
    @AppStorage(SupportPrompt.lastShownLaunchKey) private var lastShownLaunch = 0
    @State private var hasEvaluatedThisAppearance = false
    @State private var showAlert = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                // The view modifier's onAppear fires every time the view
                // re-appears (tab switch, window reactivation, etc.). Only
                // evaluate the gate once per process so the user can't see
                // the alert multiple times in a single session.
                guard !hasEvaluatedThisAppearance else { return }
                hasEvaluatedThisAppearance = true

                launchCount += 1
                let launchesSinceLastShown = launchCount - lastShownLaunch
                guard launchCount >= Self.minLaunches,
                      launchesSinceLastShown >= Self.minLaunchesBetweenPrompts,
                      Double.random(in: 0...1) < Self.showProbability else { return }
                lastShownLaunch = launchCount
                showAlert = true
            }
            .alert("Enjoying Findle?", isPresented: $showAlert) {
                Button("Star on GitHub") {
                    if let url = URL(string: "https://github.com/alexmodrono/Findle") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Buy Me a Coffee") {
                    if let url = URL(string: "https://buymeacoffee.com/amodrono") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Button("Maybe Later", role: .cancel) {}
            } message: {
                Text("Please consider leaving a star on GitHub or donating to support open-source projects like this.")
            }
    }
}

extension View {
    func supportPrompt() -> some View {
        modifier(SupportPrompt())
    }
}
