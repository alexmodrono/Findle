import SwiftUI
import Airlock
import SharedDomain

struct SetupStepView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.airlockNavigator) private var navigator

    @State private var currentActivity = "Preparing…"
    @State private var syncedCourses: [SyncedCourseInfo] = []
    @State private var totalCourses = 0
    @State private var isComplete = false
    @State private var errorMessage: String?

    struct SyncedCourseInfo: Identifiable {
        let id: Int
        let name: String
        let itemCount: Int
    }

    private var progress: Double {
        guard totalCourses > 0 else { return 0 }
        return Double(syncedCourses.count) / Double(totalCourses)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 32)

            AirlockStepHeader(
                icon: isComplete ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath",
                title: isComplete ? "Sync complete" : "Syncing your courses",
                subtitle: isComplete
                    ? "All courses have been synced to your Finder workspace."
                    : "Findle is downloading course metadata from Moodle.",
                iconColor: isComplete ? .green : .blue
            )

            ProgressBarView(
                progress: progress,
                label: currentActivity,
                showPercentage: totalCourses > 0,
                gradientColors: [.blue, .cyan]
            )
            .padding(.horizontal, 24)

            if !syncedCourses.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(syncedCourses) { course in
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 12))

                                Text(course.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)

                                Spacer()

                                Text("^[\(course.itemCount) item](inflect: true)")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .frame(maxHeight: 160)
            }

            if let errorMessage {
                InfoBanner(message: errorMessage, style: .warning)
                    .padding(.horizontal, 24)
            }

            if isComplete {
                AirlockInfoCard(
                    icon: "externaldrive.badge.checkmark",
                    title: "Finder workspace configured",
                    description: "**\(syncedCourses.count) courses** synced with **\(totalItemCount) items** available in Finder.",
                    color: .green
                )
                .padding(.horizontal, 24)
            }

            Spacer()
        }
        .airlockContinueEnabled(isComplete)
        .task {
            await runSetup()
        }
    }

    private var totalItemCount: Int {
        syncedCourses.reduce(0) { $0 + $1.itemCount }
    }

    private func runSetup() async {
        let courses = appState.courses.filter(\.isSyncEnabled)
        totalCourses = courses.count

        guard !courses.isEmpty else {
            currentActivity = "No courses selected"
            isComplete = true
            navigator?.setContinueEnabled(true)
            return
        }

        guard let site = appState.currentSite,
              let token = appState.currentToken,
              let engine = appState.syncEngine else {
            currentActivity = "Sync engine not available"
            errorMessage = "Could not start sync. You can sync later from the workspace."
            isComplete = true
            navigator?.setContinueEnabled(true)
            return
        }

        for course in courses {
            currentActivity = "Syncing \(course.shortName)…"

            do {
                try await engine.syncCourse(site: site, token: token, course: course)

                let progress = await engine.progress(forCourse: course.id)
                let itemCount = progress?.totalItems ?? 0

                syncedCourses.append(SyncedCourseInfo(
                    id: course.id,
                    name: course.fullName,
                    itemCount: itemCount
                ))
            } catch {
                syncedCourses.append(SyncedCourseInfo(
                    id: course.id,
                    name: course.fullName,
                    itemCount: 0
                ))
            }
        }

        currentActivity = "Complete"
        appState.syncStatus = .completed
        appState.lastSyncDate = Date()
        isComplete = true
        navigator?.setContinueEnabled(true)
    }
}
