import SwiftUI
import AuthenticationServices
import SharedDomain
import FoodleNetworking

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    @State private var step: OnboardingStep = .welcome
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var validatedSite: MoodleSite?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showEmbeddedSSO = false
    @State private var embeddedAuthCoordinator: EmbeddedAuthCoordinator?

    enum OnboardingStep {
        case welcome
        case serverURL
        case credentials
        case sso
        case connecting
        case complete
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .padding(.bottom, 4)

                Text("Foodle")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Access your course files right from Finder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 32)

            Divider()

            // Content
            VStack(spacing: 20) {
                switch step {
                case .welcome:
                    welcomeStep
                case .serverURL:
                    serverURLStep
                case .credentials:
                    credentialsStep
                case .sso:
                    ssoStep
                case .connecting:
                    connectingStep
                case .complete:
                    completeStep
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 520)
        .sheet(isPresented: $showEmbeddedSSO) {
            if let site = validatedSite, let coordinator = embeddedAuthCoordinator {
                EmbeddedSSOView(
                    site: site,
                    coordinator: coordinator,
                    onCancel: {
                        showEmbeddedSSO = false
                        coordinator.cancel()
                        embeddedAuthCoordinator = nil
                        withAnimation { step = .sso }
                    }
                )
            }
        }
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "folder.fill.badge.gearshape", title: "Finder Integration", description: "Course files appear directly in Finder, just like iCloud or Dropbox.")
                featureRow(icon: "arrow.down.circle.fill", title: "On-Demand Downloads", description: "Files download only when you open them, saving disk space.")
                featureRow(icon: "lock.fill", title: "Secure Connection", description: "Supports SSO (Microsoft, Google, etc.) and stores tokens securely in the macOS Keychain.")
            }

            Spacer()

            Button("Get Started") {
                withAnimation { step = .serverURL }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    private var serverURLStep: some View {
        VStack(spacing: 20) {
            Text("Connect to your Moodle site")
                .font(.headline)

            Text("Enter the URL of your institution's Moodle or Open LMS site.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("https://moodle.example.edu", text: $serverURL)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 380)
                .onSubmit { Task { await validateServer() } }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button("Back") {
                    withAnimation { step = .welcome }
                }

                Spacer()

                Button("Continue") {
                    Task { await validateServer() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(serverURL.isEmpty || isLoading)
            }
        }
    }

    private var credentialsStep: some View {
        VStack(spacing: 20) {
            siteHeader

            VStack(spacing: 12) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { Task { await signInWithPassword() } }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button("Back") {
                    errorMessage = nil
                    withAnimation { step = .serverURL }
                }

                Spacer()

                Button("Sign In") {
                    Task { await signInWithPassword() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || password.isEmpty || isLoading)
            }
        }
    }

    private var ssoStep: some View {
        VStack(spacing: 20) {
            siteHeader

            VStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)

                Text("This site uses single sign-on")
                    .font(.headline)

                Text("You'll be redirected to your institution's login page to authenticate with your existing account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)

                // Show identity provider names if available
                if let site = validatedSite, !site.capabilities.identityProviders.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(site.capabilities.identityProviders.prefix(3), id: \.name) { provider in
                            Text(provider.name)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(.quaternary)
                                .clipShape(Capsule())
                        }
                    }
                    .padding(.top, 4)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            HStack {
                Button("Back") {
                    errorMessage = nil
                    withAnimation { step = .serverURL }
                }

                Spacer()

                Button("Sign In with SSO") {
                    Task { await signInWithSSO() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
        }
    }

    private var siteHeader: some View {
        VStack(spacing: 4) {
            if let site = validatedSite {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(site.displayName)
                        .font(.headline)
                }

                if let version = site.capabilities.moodleRelease {
                    Text("Moodle \(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var connectingStep: some View {
        VStack(spacing: 20) {
            ProgressView()
                .controlSize(.large)

            Text("Connecting...")
                .font(.headline)

            Text("Setting up your File Provider and loading courses.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var completeStep: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("You're all set")
                .font(.headline)

            Text("Your courses will appear in Finder's sidebar under Foodle.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button("Open Courses") {
                appState.currentScreen = .courses
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Helpers

    private func featureRow(icon: String, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func validateServer() async {
        isLoading = true
        errorMessage = nil

        do {
            let site = try await appState.validateSite(urlString: serverURL)
            validatedSite = site

            if site.capabilities.requiresSSO {
                withAnimation { step = .sso }
            } else {
                withAnimation { step = .credentials }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func signInWithPassword() async {
        guard let site = validatedSite else { return }

        isLoading = true
        errorMessage = nil
        withAnimation { step = .connecting }

        do {
            try await appState.signIn(site: site, username: username, password: password)
            withAnimation { step = .complete }
        } catch {
            errorMessage = error.localizedDescription
            withAnimation { step = .credentials }
        }

        isLoading = false
    }

    private func signInWithSSO() async {
        guard let site = validatedSite else { return }

        isLoading = true
        errorMessage = nil

        if site.capabilities.loginType == .embedded {
            await signInWithEmbeddedSSO(site: site)
        } else {
            await signInWithBrowserSSO(site: site)
        }

        isLoading = false
    }

    private func signInWithBrowserSSO(site: MoodleSite) async {
        do {
            guard let window = NSApplication.shared.keyWindow else {
                throw FoodleError.internalError(detail: "No window available for authentication.")
            }
            let context = WindowPresentationContext(window: window)

            withAnimation { step = .connecting }
            try await appState.signInWithBrowserSSO(site: site, presentationContext: context)
            withAnimation { step = .complete }
        } catch is CancellationError {
            withAnimation { step = .sso }
        } catch let error as FoodleError where error.isCancelled {
            withAnimation { step = .sso }
        } catch {
            handleSSOError(error)
        }
    }

    private func signInWithEmbeddedSSO(site: MoodleSite) async {
        let coordinator = EmbeddedAuthCoordinator()
        embeddedAuthCoordinator = coordinator

        // Start the async auth in a detached task. authenticate() creates the
        // webView and then suspends until the callback is intercepted.
        let authTask = Task { @MainActor in
            try await coordinator.authenticate(site: site)
        }

        // Give the coordinator time to create the webView before showing the sheet.
        try? await Task.sleep(for: .milliseconds(50))
        showEmbeddedSSO = true

        do {
            let result = try await authTask.value
            showEmbeddedSSO = false
            embeddedAuthCoordinator = nil
            withAnimation { step = .connecting }
            try await appState.completeSignIn(site: site, token: result.token)
            withAnimation { step = .complete }
        } catch is CancellationError {
            showEmbeddedSSO = false
            embeddedAuthCoordinator = nil
            withAnimation { step = .sso }
        } catch let error as FoodleError where error.isCancelled {
            showEmbeddedSSO = false
            embeddedAuthCoordinator = nil
            withAnimation { step = .sso }
        } catch {
            showEmbeddedSSO = false
            embeddedAuthCoordinator = nil
            handleSSOError(error)
        }
    }

    private func handleSSOError(_ error: Error) {
        if let foodleError = error as? FoodleError {
            switch foodleError {
            case .ssoLaunchURLUnavailable:
                errorMessage = "This site requires browser sign-in, but Foodle could not build a valid sign-in URL. Please contact your Moodle administrator or try again."
            case .ssoLaunchURLInvalid:
                errorMessage = "The site's advertised sign-in URL is invalid. Please contact your Moodle administrator or try again."
            case .ssoSessionStartFailed:
                errorMessage = "Foodle could not start the browser sign-in flow for this site."
            case .ssoCallbackInvalid:
                errorMessage = "The sign-in callback from the site was invalid or incomplete. Please try again."
            default:
                errorMessage = foodleError.localizedDescription
            }
        } else {
            errorMessage = error.localizedDescription
        }
        withAnimation { step = .sso }
    }
}

// MARK: - ASWebAuthenticationSession Presentation Context

/// Provides the window anchor for ASWebAuthenticationSession.
final class WindowPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let window: NSWindow

    init(window: NSWindow) {
        self.window = window
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        window
    }
}
