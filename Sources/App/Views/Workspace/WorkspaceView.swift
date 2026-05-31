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
        case gallery
        case course(Int)
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

    /// Enabled courses (respecting the search filter) grouped by tag for the sidebar.
    private var taggedSections: [(tag: FinderTag?, courses: [MoodleCourse])] {
        appState.tagSections(for: enabledCourses)
    }

    private var hasAnyTags: Bool {
        !appState.courseTags.isEmpty
    }

    /// Total sync-enabled courses, ignoring the search filter — used for the
    /// "Sync All" tooltip count.
    private var syncAllEnabledCount: Int {
        appState.courses.filter(\.isSyncEnabled).count
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
                .help(isSyncing
                    ? "Syncing…"
                    : "Sync all \(syncAllEnabledCount) enabled course\(syncAllEnabledCount == 1 ? "" : "s")")
                .disabled(isSyncing)
            }
        }
        .task {
            if appState.courses.isEmpty {
                await appState.loadCourses()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            banners
        }
    }

    // MARK: - Banners

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 0) {
            if appState.sessionExpired {
                bannerBar(
                    icon: "person.crop.circle.badge.exclamationmark",
                    tint: .orange,
                    message: "Your session has expired. Reconnect to keep syncing.",
                    actionTitle: "Reconnect"
                ) {
                    Task { await appState.reconnect() }
                }
            } else if let error = appState.errorMessage {
                bannerBar(
                    icon: "exclamationmark.triangle.fill",
                    tint: .red,
                    message: error,
                    secondaryActionTitle: "Retry",
                    secondaryAction: { syncAll() },
                    actionTitle: "Dismiss"
                ) {
                    appState.dismissError()
                }
            }
        }
    }

    private func bannerBar(
        icon: String,
        tint: Color,
        message: String,
        secondaryActionTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(message)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle, action: secondaryAction)
                    .buttonStyle(.borderless)
            }
            Button(actionTitle, action: action)
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label("All Courses", systemImage: "square.grid.2x2")
                .tag(SidebarSelection.gallery)

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
            tags: appState.courseTags[course.id] ?? [],
            syncState: appState.courseSyncStates[course.id]
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
            case .syncing(let progress):
                if let detail = appState.syncProgressDetail, detail.total > 0 {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(width: 72)
                    Text("Syncing \(min(detail.completed + 1, detail.total)) of \(detail.total)…")
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Syncing…")
                }
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
                CourseDetailView(course: course, isSyncing: isSyncing) {
                    selection = .gallery
                }
            } else {
                ContentUnavailableView(
                    "Course Not Found",
                    systemImage: "exclamationmark.triangle",
                    description: Text("This course is no longer available.")
                )
            }
        case .gallery, nil:
            CourseGalleryView { id in
                selection = .course(id)
            }
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
