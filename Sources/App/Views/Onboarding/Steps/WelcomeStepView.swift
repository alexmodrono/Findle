import SwiftUI
import Airlock

struct WelcomeStepView: View {
    private let highlights: [AnimatedFeatureHighlight.Feature] = [
        .init(icon: "folder.badge.gearshape", title: "Finder-native sync", color: .blue),
        .init(icon: "lock.shield.fill", title: "Secure sign-in", color: .green),
        .init(icon: "arrow.down.circle.fill", title: "On-demand downloads", color: .orange),
        .init(icon: "graduationcap.fill", title: "Built for Moodle", color: .purple)
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 24)

            AnimatedFeatureHighlight(features: highlights)

            VStack(spacing: 8) {
                Text("Your course files, redesigned for macOS")
                    .font(.title2)
                    .bold()

                Text("Findle brings Moodle and Open LMS content into a proper Finder workspace.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            VStack(spacing: 10) {
                FeatureCard(
                    icon: "externaldrive.connected.to.line.below",
                    title: "Bring course materials into Finder",
                    description: "Findle creates a dedicated cloud storage domain so your course files feel like part of the Mac.",
                    accentColor: .blue,
                    showChevron: false
                )

                FeatureCard(
                    icon: "person.badge.shield.checkmark",
                    title: "Sign in the way your institution expects",
                    description: "Use direct credentials, browser SSO, or embedded sign-in.",
                    accentColor: .green,
                    showChevron: false
                )

                FeatureCard(
                    icon: "internaldrive",
                    title: "Keep storage light",
                    description: "Course metadata syncs first. Files download only when you open them.",
                    accentColor: .orange,
                    showChevron: false
                )
            }
            .padding(.horizontal, 24)

            Spacer().frame(height: 24)
        }
        .airlockEnableContinueAfter(seconds: 2)
    }
}
