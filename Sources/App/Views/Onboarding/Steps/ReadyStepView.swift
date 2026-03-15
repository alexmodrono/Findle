// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import Airlock

struct ReadyStepView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var onboardingState: OnboardingState
    @Environment(\.airlockNavigator) private var navigator

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 32)

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.08))
                    .frame(width: 120, height: 120)

                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 100, height: 100)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
            }
            .scaleEffect(appeared ? 1.0 : 0.8)
            .opacity(appeared ? 1.0 : 0)

            VStack(spacing: 8) {
                Text("Workspace ready")
                    .font(.title2)
                    .bold()

                Text("Your courses are available in Finder whenever you need them.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }

            if let site = onboardingState.validatedSite {
                AirlockInfoCard(
                    icon: "checkmark.circle.fill",
                    title: site.displayName,
                    description: "**\(site.baseURL.host ?? site.baseURL.absoluteString)** — \(courseSummary)",
                    color: .green
                )
                .padding(.horizontal, 24)
                .opacity(appeared ? 1.0 : 0)
            }

            FeatureGrid(
                features: [
                    .init(icon: "folder.badge.gearshape", title: "Finder-native", description: "Browse course files in Finder", color: .blue),
                    .init(icon: "arrow.down.circle.fill", title: "On-demand", description: "Files download when opened", color: .green),
                    .init(icon: "lock.shield.fill", title: "Secure", description: "Keychain-stored credentials", color: .purple),
                    .init(icon: "arrow.triangle.2.circlepath", title: "Auto-sync", description: "Courses stay up to date", color: .orange)
                ],
                columns: 2
            )
            .padding(.horizontal, 24)
            .opacity(appeared ? 1.0 : 0)

            Spacer().frame(height: 24)
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                appeared = true
            }
            navigator?.setButtonLabel("Open Workspace", icon: "sidebar.left")
            navigator?.setContinueEnabled(true)
        }
    }

    private var courseSummary: String {
        let count = appState.courses.count
        if count == 0 { return "No courses loaded yet" }
        if count == 1 { return "1 course loaded" }
        return "\(count) courses loaded"
    }
}
