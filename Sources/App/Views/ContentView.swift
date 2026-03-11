import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Group {
            switch appState.currentScreen {
            case .onboarding:
                OnboardingView()
            case .courses:
                CoursesView()
            case .settings:
                SettingsView()
            case .diagnostics:
                DiagnosticsView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.currentScreen)
    }
}
