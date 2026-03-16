// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import Airlock
import AuthenticationServices
import SharedDomain
import FoodleNetworking

struct SignInStepView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var onboardingState: OnboardingState
    @Environment(\.airlockNavigator) private var navigator

    @State private var signInCompleted = false

    private var site: MoodleSite? {
        onboardingState.validatedSite
    }

    private var requiresSSO: Bool {
        site?.capabilities.requiresSSO ?? false
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 32)

            AirlockStepHeader(
                icon: signInCompleted ? "checkmark.circle.fill" : (requiresSSO ? "globe" : "lock.fill"),
                title: signInCompleted ? "Signed In" : (requiresSSO ? "Institutional sign-in" : "Sign in to your account"),
                subtitle: signInCompleted
                    ? "Authenticated successfully."
                    : (requiresSSO
                        ? "Findle has detected a single sign-on workflow for this site."
                        : "Use the credentials your Moodle site accepts directly."),
                iconColor: signInCompleted ? .green : (requiresSSO ? .purple : .blue)
            )

            VStack(alignment: .leading, spacing: 16) {
                if let site {
                    AirlockInfoCard(
                        icon: "server.rack",
                        title: site.displayName,
                        description: site.capabilities.moodleRelease.map { "Moodle \($0)" } ?? "Moodle-compatible site",
                        color: .blue
                    )
                }

                if !signInCompleted {
                    if requiresSSO {
                        ssoContent
                    } else {
                        credentialsContent
                    }
                }

                if let errorMessage = onboardingState.errorMessage {
                    InfoBanner(message: errorMessage, style: .warning)
                }

                if signInCompleted {
                    InfoBanner(message: "Credentials stored securely in Keychain.", style: .success)
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .onAppear(perform: configureButton)
        .onChange(of: onboardingState.username) { _, _ in
            guard !signInCompleted, !requiresSSO else { return }
            updateCredentialsEnabled()
        }
        .onChange(of: onboardingState.password) { _, _ in
            guard !signInCompleted, !requiresSSO else { return }
            updateCredentialsEnabled()
        }
    }

    private var ssoContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let site, !site.capabilities.identityProviders.isEmpty {
                AirlockCapabilityChips(
                    site.capabilities.identityProviders.prefix(4).map { provider in
                        (icon: "person.crop.rectangle.stack.fill", label: provider.name, color: Color.purple)
                    }
                )
            }

            AirlockInfoCard(
                icon: "info.circle.fill",
                title: "How it works",
                description: "Findle will open your institution's identity provider. Sign-in completes automatically when the provider redirects back.",
                color: .purple
            )
        }
    }

    private var credentialsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Username", text: $onboardingState.username)
                .textFieldStyle(.roundedBorder)
                .font(.title3)

            SecureField("Password", text: $onboardingState.password)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .onSubmit { navigator?.goToNext() }
        }
    }

    // MARK: - Button Configuration

    private func configureButton() {
        if requiresSSO {
            navigator?.setButtonAction(label: "Sign In with SSO", icon: "globe") { [self] in
                await signInWithSSO()
            }
            navigator?.setContinueEnabled(true)
        } else {
            navigator?.setButtonAction(label: "Sign In", icon: "lock.open.fill") { [self] in
                await signInWithPassword()
            }
            updateCredentialsEnabled()
        }
    }

    private func updateCredentialsEnabled() {
        let ready = !onboardingState.username.isEmpty && !onboardingState.password.isEmpty
        navigator?.setContinueEnabled(ready)
    }

    // MARK: - Auth Actions

    private func signInWithPassword() async {
        guard let site else { return }

        onboardingState.errorMessage = nil
        navigator?.setContinueEnabled(false)

        do {
            try await appState.signInAndPersist(site: site, username: onboardingState.username, password: onboardingState.password)
            signInCompleted = true
            navigator?.resetButton()
            navigator?.setContinueEnabled(true)
        } catch {
            onboardingState.errorMessage = error.localizedDescription
            updateCredentialsEnabled()
        }
    }

    private func signInWithSSO() async {
        guard let site else { return }

        onboardingState.errorMessage = nil
        navigator?.setContinueEnabled(false)

        if site.capabilities.loginType == .embedded {
            await signInWithEmbeddedSSO(site: site)
        } else {
            await signInWithBrowserSSO(site: site)
        }
    }

    private func signInWithBrowserSSO(site: MoodleSite) async {
        do {
            guard let window = NSApplication.shared.keyWindow else {
                throw FoodleError.internalError(detail: "No window available for authentication.")
            }

            let context = WindowPresentationContext(window: window)
            try await appState.signInWithBrowserSSOAndPersist(site: site, presentationContext: context)
            signInCompleted = true
            navigator?.resetButton()
            navigator?.setContinueEnabled(true)
        } catch is CancellationError {
            navigator?.setContinueEnabled(true)
        } catch let error as FoodleError where error.isCancelled {
            navigator?.setContinueEnabled(true)
        } catch {
            handleSSOError(error)
            navigator?.setContinueEnabled(true)
        }
    }

    private func signInWithEmbeddedSSO(site: MoodleSite) async {
        let coordinator = EmbeddedAuthCoordinator()

        do {
            try coordinator.configure(site: site)
        } catch {
            handleSSOError(error)
            navigator?.setContinueEnabled(true)
            return
        }

        // Show the sheet first so the web view is in the window hierarchy before
        // loading the URL. In sandboxed release builds, WebKit's networking process
        // needs the view in a valid window for cross-origin SSO redirects to work.
        onboardingState.embeddedAuthCoordinator = coordinator
        onboardingState.showEmbeddedSSO = true

        do {
            let result = try await coordinator.waitForResult()
            onboardingState.showEmbeddedSSO = false
            onboardingState.embeddedAuthCoordinator = nil

            try await appState.persistSignIn(site: site, token: result.token)
            signInCompleted = true
            navigator?.resetButton()
            navigator?.setContinueEnabled(true)
        } catch is CancellationError {
            onboardingState.showEmbeddedSSO = false
            onboardingState.embeddedAuthCoordinator = nil
            navigator?.setContinueEnabled(true)
        } catch let error as FoodleError where error.isCancelled {
            onboardingState.showEmbeddedSSO = false
            onboardingState.embeddedAuthCoordinator = nil
            navigator?.setContinueEnabled(true)
        } catch {
            onboardingState.showEmbeddedSSO = false
            onboardingState.embeddedAuthCoordinator = nil
            handleSSOError(error)
            navigator?.setContinueEnabled(true)
        }
    }

    private func handleSSOError(_ error: Error) {
        if let foodleError = error as? FoodleError {
            switch foodleError {
            case .ssoLaunchURLUnavailable:
                onboardingState.errorMessage = "This site requires sign-in through its identity provider, but Findle could not build a valid launch URL."
            case .ssoLaunchURLInvalid:
                onboardingState.errorMessage = "The site's advertised sign-in URL is invalid. Please try again or contact your Moodle administrator."
            case .ssoSessionStartFailed:
                onboardingState.errorMessage = "Findle could not start the sign-in session for this site."
            case .ssoCallbackInvalid:
                onboardingState.errorMessage = "The sign-in callback from the site was invalid or incomplete. Please try again."
            default:
                onboardingState.errorMessage = foodleError.localizedDescription
            }
        } else {
            onboardingState.errorMessage = error.localizedDescription
        }
    }
}
