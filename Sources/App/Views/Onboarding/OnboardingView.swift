// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import Airlock
import SharedDomain
import FoodleNetworking

struct OnboardingView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var onboardingState = OnboardingState()

    @StateObject private var navigator = AirlockNavigator(
        appName: "Findle",
        appIconName: "OnboardingIcon",
        steps: makeSteps()
    )

    var body: some View {
        AirlockFlowView(
            navigator: navigator,
            configuration: AirlockConfiguration(
                showIntro: true,
                introDuration: 2.5,
                playIntroSound: true,
                allowSkipIntro: true,
                onDismiss: {
                    DispatchQueue.main.async {
                        NSApplication.shared.terminate(nil)
                    }
                }
            )
        )
        .environmentObject(onboardingState)
        .onChange(of: navigator.isActive) { _, isActive in
            if !isActive {
                appState.currentScreen = .workspace
            }
        }
        .sheet(isPresented: $onboardingState.showEmbeddedSSO) {
            if let site = onboardingState.validatedSite,
               let coordinator = onboardingState.embeddedAuthCoordinator {
                EmbeddedSSOView(
                    site: site,
                    coordinator: coordinator,
                    onCancel: cancelEmbeddedSSO
                )
            }
        }
    }

    private func cancelEmbeddedSSO() {
        onboardingState.showEmbeddedSSO = false
        onboardingState.embeddedAuthCoordinator?.cancel()
        onboardingState.embeddedAuthCoordinator = nil
    }

    @MainActor
    private static func makeSteps() -> [AnyAirlockStep] {
        [
            AnyAirlockStep(AirlockStep(
                id: "welcome",
                title: "Welcome",
                icon: "graduationcap.fill",
                subtitle: "Get started with Findle"
            ) {
                WelcomeStepView()
            }),
            AnyAirlockStep(AirlockStep(
                id: "server",
                title: "Server",
                icon: "network",
                subtitle: "Connect your Moodle site"
            ) {
                ServerStepView()
            }),
            AnyAirlockStep(AirlockStep(
                id: "signin",
                title: "Sign In",
                icon: "lock.shield.fill",
                subtitle: "Authenticate with your site"
            ) {
                SignInStepView()
            }),
            AnyAirlockStep(AirlockStep(
                id: "courses",
                title: "Courses",
                icon: "square.stack.3d.up.fill",
                subtitle: "Choose courses to sync"
            ) {
                CoursesStepView()
            }),
            AnyAirlockStep(AirlockStep(
                id: "setup",
                title: "Setup",
                icon: "gearshape.fill",
                subtitle: "Prepare your workspace"
            ) {
                SetupStepView()
            }),
            AnyAirlockStep(AirlockStep(
                id: "ready",
                title: "Ready",
                icon: "checkmark.circle.fill",
                subtitle: "Start using Findle"
            ) {
                ReadyStepView()
            })
        ]
    }
}
