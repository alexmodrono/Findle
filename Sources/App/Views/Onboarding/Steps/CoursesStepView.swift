import SwiftUI
import Airlock
import SharedDomain

struct CoursesStepView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.airlockNavigator) private var navigator

    @State private var isLoading = true
    @State private var errorMessage: String?

    private var enabledCount: Int {
        appState.courses.filter(\.isSyncEnabled).count
    }

    private var allEnabled: Bool {
        !appState.courses.isEmpty && appState.courses.allSatisfy(\.isSyncEnabled)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 32)

            AirlockStepHeader(
                icon: "square.stack.3d.up.fill",
                title: isLoading ? "Loading courses" : "Choose your courses",
                subtitle: isLoading
                    ? "Fetching enrolled courses from Moodle…"
                    : "Select which courses to sync to Finder. You can change this later.",
                iconColor: .blue
            )

            if isLoading {
                ProgressView()
                    .controlSize(.regular)
                    .padding(.top, 8)
            } else if appState.courses.isEmpty {
                AirlockInfoCard(
                    icon: "exclamationmark.triangle.fill",
                    title: "No courses found",
                    description: "No enrolled courses were found on this site. You can continue and check again later from the workspace.",
                    color: .orange
                )
                .padding(.horizontal, 24)
            } else {
                HStack {
                    Text("^[\(enabledCount) course](inflect: true) selected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(allEnabled ? "Deselect All" : "Select All") {
                        let newValue = !allEnabled
                        for course in appState.courses {
                            if course.isSyncEnabled != newValue {
                                appState.setCourseSyncEnabled(newValue, for: course)
                            }
                        }
                    }
                    .buttonStyle(.link)
                    .font(.subheadline)
                }
                .padding(.horizontal, 24)

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(appState.courses) { course in
                            courseRow(course)
                            if course.id != appState.courses.last?.id {
                                Divider()
                                    .padding(.leading, 40)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .frame(maxHeight: 260)
            }

            if let errorMessage {
                InfoBanner(message: errorMessage, style: .warning)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .airlockContinueEnabled(!isLoading)
        .task {
            await loadCourses()
        }
    }

    @ViewBuilder
    private func courseRow(_ course: MoodleCourse) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(course.isSyncEnabled ? Color.blue : Color.secondary.opacity(0.3))
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 2) {
                Text(course.fullName)
                    .lineLimit(2)
                Text(course.shortName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { course.isSyncEnabled },
                set: { appState.setCourseSyncEnabled($0, for: course) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .opacity(course.isSyncEnabled ? 1.0 : 0.6)
    }

    private func loadCourses() async {
        appState.activateAfterOnboarding()
        await appState.loadCourses()

        if appState.courses.isEmpty {
            errorMessage = "No courses were returned by the server."
        }

        isLoading = false
    }
}
