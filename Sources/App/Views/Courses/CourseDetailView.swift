// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import AppKit
import SharedDomain

struct CourseDetailView: View {
    @EnvironmentObject private var appState: AppState

    let course: MoodleCourse
    let isSyncing: Bool
    var onShowGallery: () -> Void = {}

    @State private var customFolderName = ""
    @State private var tags: [FinderTag] = []
    @State private var isAddingTag = false
    @State private var newTagName = ""
    @State private var newTagColor: FinderTag.Color = .blue
    @State private var localSyncEnabled = true
    @State private var customIconName: String?
    @State private var isPickingIcon = false
    @State private var contents: AppState.CourseContents = .empty

    private static let scrollSpace = "courseScroll"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                stretchyHero

                VStack(alignment: .leading, spacing: 20) {
                    metricsRow
                    actionRow

                    if !contents.sections.isEmpty {
                        contentsCard
                    }

                    if let summary = cleanedSummary {
                        aboutCard(summary)
                    }

                    customizeCard
                }
                .padding(24)
            }
        }
        .coordinateSpace(name: Self.scrollSpace)
        .navigationTitle(course.effectiveFolderName)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("All Courses", systemImage: "square.grid.2x2", action: onShowGallery)
                    .help("Back to all courses")
            }
            // Per-course sync lives as a prominent button in the action row, so
            // it's intentionally omitted here to avoid two near-identical sync
            // glyphs sitting next to the toolbar's "Sync All".
        }
        .task(id: course.id) {
            loadCustomization()
            loadContents()
        }
        .onChange(of: appState.courseSyncStates[course.id]) {
            // Re-read counts/last-synced whenever this course's sync state moves
            // (e.g. a sync just finished and new items landed).
            loadContents()
        }
    }

    // MARK: - Hero

    private static let heroHeight: CGFloat = 240

    /// An elastic header: the cover stretches downward when the scroll view is
    /// over-scrolled past the top. The image lives in `.background` so its
    /// `scaledToFill` overflow can't grow the frame and push the title out of
    /// the clipped region — the title stays pinned to the bottom edge.
    private var stretchyHero: some View {
        GeometryReader { geo in
            let minY = geo.frame(in: .named(Self.scrollSpace)).minY
            let stretch = max(0, minY)

            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.15), .black.opacity(0.65)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                heroTitle
            }
            .frame(width: geo.size.width, height: Self.heroHeight + stretch)
            .background {
                coverBackground
            }
            .clipped()
            .offset(y: -stretch)
        }
        .frame(height: Self.heroHeight)
    }

    private var heroTitle: some View {
        VStack(alignment: .leading, spacing: 8) {
            statusPill

            Text(course.fullName)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.4), radius: 5, y: 1)

            HStack(spacing: 6) {
                Text(course.shortName)
                if let range = formattedDateRange {
                    Text("·").foregroundStyle(.white.opacity(0.5))
                    Text(range)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var coverBackground: some View {
        if let cover = appState.courseCoverImages[course.id] {
            Image(nsImage: cover)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [coverColor, coverColor.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: customIconName ?? "folder.fill")
                    .font(.system(size: 96, weight: .medium))
                    .foregroundStyle(.white.opacity(0.18))
            }
        }
    }

    private var statusPill: some View {
        let appearance = statusAppearance
        return Label(appearance.text, systemImage: appearance.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(appearance.tint.opacity(0.9), in: Capsule())
    }

    // MARK: - Metrics

    private var metricsRow: some View {
        HStack(spacing: 12) {
            metricCard(
                value: "\(contents.fileCount)",
                label: contents.fileCount == 1 ? "File" : "Files",
                systemImage: "doc"
            )
            metricCard(
                value: contents.totalBytes > 0 ? contents.totalBytes.formatted(.byteCount(style: .file)) : "—",
                label: "Size",
                systemImage: "internaldrive"
            )
            metricCard(
                value: "\(contents.downloadedCount)",
                label: "Downloaded",
                systemImage: "arrow.down.circle"
            )
        }
    }

    private func metricCard(value: String, label: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(value)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Actions row

    private var isThisCourseSyncing: Bool {
        appState.courseSyncStates[course.id] == .syncing
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                Task { await appState.openFileProviderInFinder(selecting: course) }
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!localSyncEnabled)

            Button(action: syncCourse) {
                HStack(spacing: 6) {
                    if isThisCourseSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isThisCourseSyncing ? "Syncing…" : "Sync")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isSyncing || isThisCourseSyncing || !localSyncEnabled)
        }
    }

    // MARK: - Cards

    private var contentsCard: some View {
        sectionCard(title: "Contents", systemImage: "list.bullet.rectangle") {
            VStack(spacing: 0) {
                ForEach(Array(contents.sections.enumerated()), id: \.element.id) { index, section in
                    if index > 0 {
                        Divider()
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.tint)
                        Text(section.name)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(section.fileCount)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func aboutCard(_ summary: String) -> some View {
        sectionCard(title: "About", systemImage: "text.alignleft") {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var customizeCard: some View {
        sectionCard(title: "Customize", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 18) {
                // Tappable icon tile + inline-editable folder name.
                HStack(spacing: 14) {
                    iconTile

                    VStack(alignment: .leading, spacing: 2) {
                        TextField(course.sanitizedFolderName, text: $customFolderName)
                            .textFieldStyle(.plain)
                            .font(.title3.weight(.semibold))
                            .onSubmit { saveFolderName() }

                        Text(course.shortName)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                // Tags as removable pills with an add chip.
                FlowLayout(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in
                        TagBadge(tag: tag) {
                            removeTag(tag)
                        }
                    }

                    Button {
                        isAddingTag = true
                    } label: {
                        Label("Tag", systemImage: "plus")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.quaternary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isAddingTag) {
                        AddTagPopover(
                            name: $newTagName,
                            color: $newTagColor,
                            onAdd: { addTag() },
                            onCancel: { isAddingTag = false }
                        )
                    }
                }

                Toggle("Sync this course", isOn: $localSyncEnabled)
                    .onChange(of: localSyncEnabled) { oldValue, newValue in
                        // Skip when the change comes from loadCustomization()
                        // re-syncing the @State from the course model. Without
                        // this guard, switching between courses re-applies the
                        // same value and can trigger a redundant File Provider
                        // signal that wipes recently-discovered items.
                        guard oldValue != newValue, newValue != course.isSyncEnabled else { return }
                        appState.setCourseSyncEnabled(newValue, for: course)
                    }

                if !localSyncEnabled {
                    Text("This course will be skipped during sync and hidden from Finder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var iconTile: some View {
        Button {
            isPickingIcon = true
        } label: {
            Image(systemName: customIconName ?? "folder.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(
                    coverColor.opacity(0.16),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .tint)
                        .offset(x: 5, y: 5)
                }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPickingIcon) {
            IconPickerView(selectedIcon: $customIconName) {
                isPickingIcon = false
                saveIconName()
            }
        }
    }

    private func sectionCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Computed

    private var cardBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    private var coverColor: Color {
        let hue = Double(abs(course.id) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.72)
    }

    private var statusAppearance: (text: String, icon: String, tint: Color) {
        switch appState.courseSyncStates[course.id] {
        case .syncing:
            return ("Syncing…", "arrow.triangle.2.circlepath", .blue)
        case .error:
            return ("Sync failed", "exclamationmark.triangle.fill", .orange)
        default:
            if let last = contents.lastSynced {
                return ("Synced \(last.formatted(.relative(presentation: .named)))", "checkmark.circle.fill", .green)
            }
            return ("Not synced yet", "clock", .gray)
        }
    }

    private var formattedDateRange: String? {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        switch (course.startDate, course.endDate) {
        case let (start?, end?):
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        case let (start?, nil):
            return "From \(formatter.string(from: start))"
        case let (nil, end?):
            return "Until \(formatter.string(from: end))"
        case (nil, nil):
            return nil
        }
    }

    private var cleanedSummary: String? {
        guard let summary = course.summary else { return nil }
        let cleaned = summary
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Actions

    private func loadCustomization() {
        customFolderName = course.customFolderName ?? ""
        customIconName = course.customIconName
        tags = appState.fetchCourseTags(for: course)
        localSyncEnabled = course.isSyncEnabled
    }

    private func loadContents() {
        contents = appState.courseContents(for: course)
    }

    private func saveFolderName() {
        let trimmed = customFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.updateCustomFolderName(for: course, name: trimmed.isEmpty ? nil : trimmed)
    }

    private func saveIconName() {
        appState.updateCourseCustomIcon(for: course, iconName: customIconName)
    }

    private func addTag() {
        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !tags.contains(where: { $0.name == trimmed }) else { return }

        let tag = FinderTag(name: trimmed, color: newTagColor)
        tags.append(tag)
        appState.updateCourseTags(for: course, tags: tags)

        newTagName = ""
        newTagColor = .blue
        isAddingTag = false
    }

    private func removeTag(_ tag: FinderTag) {
        tags.removeAll { $0 == tag }
        appState.updateCourseTags(for: course, tags: tags)
    }

    private func syncCourse() {
        Task { await appState.syncCourse(course) }
    }
}
