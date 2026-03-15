// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import SharedDomain

struct WorkspaceView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: SidebarSelection?
    @State private var searchText = ""
    @State private var isSyncing = false

    enum SidebarSelection: Hashable {
        case course(Int)
        case settings
        case diagnostics
    }

    private var filteredCourses: [MoodleCourse] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return appState.courses }
        return appState.courses.filter {
            $0.fullName.localizedCaseInsensitiveContains(trimmed) ||
            $0.shortName.localizedCaseInsensitiveContains(trimmed) ||
            ($0.customFolderName?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    private var enabledCourses: [MoodleCourse] {
        filteredCourses.filter(\.isSyncEnabled)
    }

    private var disabledCourses: [MoodleCourse] {
        filteredCourses.filter { !$0.isSyncEnabled }
    }

    /// Enabled courses grouped by tag for sidebar display.
    private var taggedSections: [(tag: FinderTag?, courses: [MoodleCourse])] {
        let courses = enabledCourses
        let allTags = appState.courseTags

        // Collect unique tags in use, sorted by name
        var usedTags: [FinderTag] = []
        var seen = Set<String>()
        for tags in allTags.values {
            for tag in tags where !seen.contains(tag.name) {
                usedTags.append(tag)
                seen.insert(tag.name)
            }
        }
        usedTags.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard !usedTags.isEmpty else { return [] }

        var sections: [(tag: FinderTag?, courses: [MoodleCourse])] = []

        for tag in usedTags {
            let matching = courses.filter { course in
                allTags[course.id]?.contains(where: { $0.name == tag.name }) ?? false
            }
            if !matching.isEmpty {
                sections.append((tag: tag, courses: matching))
            }
        }

        // Untagged courses
        let untagged = courses.filter { allTags[$0.id]?.isEmpty ?? true }
        if !untagged.isEmpty {
            sections.append((tag: nil, courses: untagged))
        }

        return sections
    }

    private var hasAnyTags: Bool {
        !appState.courseTags.isEmpty
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
        }
        .toolbar(id: "workspace") {
            ToolbarItem(id: "openInFinder", placement: .primaryAction) {
                Button("Open in Finder", systemImage: "folder", action: openInFinder)
                    .help("Reveal in Finder")
                    .disabled(appState.currentSite == nil)
            }

            ToolbarItem(id: "syncAll", placement: .primaryAction) {
                Button {
                    syncAll()
                } label: {
                    if isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Sync All", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .help(isSyncing ? "Syncing…" : "Sync all enabled courses")
                .disabled(isSyncing)
            }
        }
        .task {
            if appState.courses.isEmpty {
                await appState.loadCourses()
            }
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            if filteredCourses.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "No Courses",
                        systemImage: "books.vertical",
                        description: Text("Sync to load your enrolled courses.")
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView.search
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            } else if hasAnyTags {
                ForEach(taggedSections, id: \.tag) { section in
                    Section {
                        ForEach(section.courses) { course in
                            courseRowItem(course)
                        }
                    } header: {
                        if let tag = section.tag {
                            HStack(spacing: 5) {
                                Circle()
                                    .fill(tag.color.swiftUIColor)
                                    .frame(width: 8, height: 8)
                                Text(tag.name)
                            }
                        } else {
                            Text("Other")
                        }
                    }
                }
            } else {
                if !enabledCourses.isEmpty {
                    Section("Enrolled Courses") {
                        ForEach(enabledCourses) { course in
                            courseRowItem(course)
                        }
                    }
                }
            }

            if !disabledCourses.isEmpty {
                Section("Not Synced") {
                    ForEach(disabledCourses) { course in
                        courseRowItem(course)
                    }
                }
            }

            Section {
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarSelection.settings)
                Label("Diagnostics", systemImage: "stethoscope")
                    .tag(SidebarSelection.diagnostics)
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $searchText, prompt: "Filter courses")
        .navigationTitle("Findle")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            statusBar
        }
    }

    private func courseRowItem(_ course: MoodleCourse) -> some View {
        CourseRow(
            course: course,
            tags: appState.courseTags[course.id] ?? []
        )
        .tag(SidebarSelection.course(course.id))
        .contextMenu {
            Button("Sync This Course") {
                Task { await appState.syncCourse(course) }
            }
            .disabled(isSyncing || !course.isSyncEnabled)

            Button("Open in Finder") {
                Task { await appState.openFileProviderInFinder(selecting: course) }
            }
            .disabled(!course.isSyncEnabled)

            Divider()

            Button(course.isSyncEnabled ? "Disable Sync" : "Enable Sync") {
                appState.setCourseSyncEnabled(!course.isSyncEnabled, for: course)
            }
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            switch appState.syncStatus {
            case .syncing:
                ProgressView()
                    .controlSize(.small)
                Text("Syncing…")
            case .completed:
                if let date = appState.lastSyncDate {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Last synced \(date, format: .relative(presentation: .named))")
                }
            case .error(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .lineLimit(1)
            case .idle:
                if let date = appState.lastSyncDate {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    Text("Last synced \(date, format: .relative(presentation: .named))")
                }
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailContent: some View {
        switch selection {
        case .course(let id):
            if let course = appState.courses.first(where: { $0.id == id }) {
                CourseDetailView(course: course, isSyncing: isSyncing)
            } else {
                ContentUnavailableView(
                    "Course Not Found",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This course is no longer available.")
                )
            }
        case .settings:
            SettingsView()
        case .diagnostics:
            DiagnosticsView()
        case nil:
            ContentUnavailableView(
                "Select a Course",
                systemImage: "books.vertical",
                description: Text("Choose a course from the sidebar to view its details.")
            )
        }
    }

    private func syncAll() {
        Task {
            isSyncing = true
            await appState.syncAll()
            isSyncing = false
        }
    }

    private func openInFinder() {
        Task { await appState.openFileProviderInFinder() }
    }
}
