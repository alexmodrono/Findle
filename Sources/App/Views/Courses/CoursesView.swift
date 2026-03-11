import SwiftUI
import SharedDomain

struct CoursesView: View {
    @EnvironmentObject var appState: AppState
    @State private var searchText = ""
    @State private var selectedCourse: MoodleCourse?
    @State private var isSyncing = false

    var filteredCourses: [MoodleCourse] {
        if searchText.isEmpty {
            return appState.courses
        }
        return appState.courses.filter {
            $0.fullName.localizedCaseInsensitiveContains(searchText) ||
            $0.shortName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Courses")
        .toolbar {
            toolbarContent
        }
        .searchable(text: $searchText, prompt: "Search courses")
        .task {
            if appState.courses.isEmpty {
                await appState.loadCourses()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(filteredCourses, selection: $selectedCourse) { course in
            CourseRow(course: course)
                .tag(course)
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
        .overlay {
            if appState.courses.isEmpty {
                ContentUnavailableView(
                    "No Courses",
                    systemImage: "graduationcap",
                    description: Text("No courses found. Try syncing.")
                )
            }
        }
    }

    // MARK: - Detail

    private var detail: some View {
        Group {
            if let course = selectedCourse {
                CourseDetailView(course: course)
            } else {
                ContentUnavailableView(
                    "Select a Course",
                    systemImage: "sidebar.left",
                    description: Text("Choose a course from the sidebar to view its contents.")
                )
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task {
                    isSyncing = true
                    await appState.syncAll()
                    isSyncing = false
                }
            } label: {
                if isSyncing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            .disabled(isSyncing)
            .help("Sync all courses")
        }

        ToolbarItem {
            Menu {
                Button("Settings") {
                    appState.currentScreen = .settings
                }
                Button("Diagnostics") {
                    appState.currentScreen = .diagnostics
                }
                Divider()
                Button("Sign Out", role: .destructive) {
                    Task { await appState.logout() }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

// MARK: - Course Row

struct CourseRow: View {
    let course: MoodleCourse

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(course.fullName)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)

            Text(course.shortName)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Course Detail

struct CourseDetailView: View {
    @EnvironmentObject var appState: AppState
    let course: MoodleCourse

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text(course.fullName)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(course.shortName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Course info
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                if let start = course.startDate {
                    GridRow {
                        Text("Start Date")
                            .foregroundStyle(.secondary)
                        Text(start, style: .date)
                    }
                }
                if let end = course.endDate {
                    GridRow {
                        Text("End Date")
                            .foregroundStyle(.secondary)
                        Text(end, style: .date)
                    }
                }
                if let summary = course.summary, !summary.isEmpty {
                    GridRow {
                        Text("Summary")
                            .foregroundStyle(.secondary)
                        Text(stripHTML(summary))
                            .lineLimit(3)
                    }
                }
            }
            .font(.subheadline)

            Spacer()

            // Actions
            HStack {
                Button("Sync This Course") {
                    Task { await appState.syncCourse(course) }
                }
                .buttonStyle(.borderedProminent)

                Button("Open in Finder") {
                    openInFinder()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func openInFinder() {
        // Open the File Provider domain folder in Finder
        NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/CloudStorage/Foodle-\(course.sanitizedFolderName)"))
    }

    private func stripHTML(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
