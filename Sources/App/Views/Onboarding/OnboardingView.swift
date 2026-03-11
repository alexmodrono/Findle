import SwiftUI
import SharedDomain

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState

    @State private var step: OnboardingStep = .welcome
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var validatedSite: MoodleSite?
    @State private var isLoading = false
    @State private var errorMessage: String?

    enum OnboardingStep {
        case welcome
        case serverURL
        case credentials
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
                case .connecting:
                    connectingStep
                case .complete:
                    completeStep
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 480)
    }

    // MARK: - Steps

    private var welcomeStep: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                featureRow(icon: "folder.fill.badge.gearshape", title: "Finder Integration", description: "Course files appear directly in Finder, just like iCloud or Dropbox.")
                featureRow(icon: "arrow.down.circle.fill", title: "On-Demand Downloads", description: "Files download only when you open them, saving disk space.")
                featureRow(icon: "lock.fill", title: "Secure Connection", description: "Your credentials are stored securely in the macOS Keychain.")
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

            VStack(spacing: 12) {
                TextField("Username", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)

                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                    .onSubmit { Task { await signIn() } }
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
                    Task { await signIn() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.isEmpty || password.isEmpty || isLoading)
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
            validatedSite = try await appState.validateSite(urlString: serverURL)
            withAnimation { step = .credentials }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func signIn() async {
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
}
