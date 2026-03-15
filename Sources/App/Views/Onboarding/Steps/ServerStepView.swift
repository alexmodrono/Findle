// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import Airlock
import SharedDomain

struct ServerStepView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var onboardingState: OnboardingState
    @Environment(\.airlockNavigator) private var navigator

    @State private var isLoading = false

    private var isValidated: Bool {
        onboardingState.validatedSite != nil
    }

    private var isURLPlausible: Bool {
        let trimmed = onboardingState.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let host = url.host else { return false }
        return host.contains(".")
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 32)

            AirlockStepHeader(
                icon: isValidated ? "checkmark.circle.fill" : "network",
                title: "Connect your site",
                subtitle: "Enter the address of your Moodle or Open LMS instance so Findle can discover the supported sign-in flow.",
                iconColor: isValidated ? .green : .blue
            )

            VStack(alignment: .leading, spacing: 16) {
                TextField("https://moodle.example.edu", text: $onboardingState.serverURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.title3)
                    .onSubmit { navigator?.goToNext() }
                    .disabled(isValidated)

                if isLoading {
                    InfoBanner(message: "Checking Moodle mobile services…", style: .info)
                }

                if let errorMessage = onboardingState.errorMessage {
                    InfoBanner(message: errorMessage, style: .warning)
                }

                if let site = onboardingState.validatedSite {
                    AirlockInfoCard(
                        icon: "checkmark.circle.fill",
                        title: site.displayName,
                        description: "**\(site.baseURL.host ?? site.baseURL.absoluteString)**\n\(site.capabilities.moodleRelease.map { "Moodle \($0)" } ?? "Moodle-compatible site")",
                        color: .green
                    )
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .onAppear(perform: configureButton)
        .onChange(of: onboardingState.serverURL) { _, _ in
            guard !isValidated else { return }
            navigator?.setContinueEnabled(isURLPlausible && !isLoading)
        }
        .onChange(of: isValidated) { _, validated in
            if validated {
                navigator?.resetButton()
                navigator?.setContinueEnabled(true)
            } else {
                configureButton()
            }
        }
    }

    private func configureButton() {
        guard !isValidated else { return }
        navigator?.setButtonAction(label: "Validate", icon: "magnifyingglass") { [self] in
            await validateServer()
        }
        navigator?.setContinueEnabled(isURLPlausible && !isLoading)
    }

    private func validateServer() async {
        isLoading = true
        onboardingState.errorMessage = nil
        navigator?.setContinueEnabled(false)

        do {
            let site = try await appState.validateSite(urlString: onboardingState.serverURL)
            onboardingState.validatedSite = site
        } catch {
            onboardingState.errorMessage = error.localizedDescription
            onboardingState.validatedSite = nil
            navigator?.setContinueEnabled(true)
        }

        isLoading = false
    }
}
