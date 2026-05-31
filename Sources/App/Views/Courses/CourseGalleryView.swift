// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import SharedDomain

/// A Books-style gallery of synced courses, shown in the detail pane when no
/// course is selected. Courses are grouped into tag "shelves"; tapping a cover
/// selects that course and reveals its detail view. Disabled (not-synced)
/// courses are hidden — the sidebar's "Not Synced" section is where they live.
struct CourseGalleryView: View {
    @EnvironmentObject private var appState: AppState

    /// Called with the course id when a cover is tapped.
    var onSelectCourse: (Int) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 20)]

    /// Tag shelves over the enabled courses. Falls back to a single untagged
    /// shelf when the user hasn't created any tags yet.
    private var sections: [(tag: FinderTag?, courses: [MoodleCourse])] {
        let enabled = appState.courses.filter(\.isSyncEnabled)
        let tagged = appState.tagSections(for: enabled)
        if tagged.isEmpty {
            return enabled.isEmpty ? [] : [(tag: nil, courses: enabled)]
        }
        return tagged
    }

    var body: some View {
        Group {
            if sections.isEmpty {
                ContentUnavailableView(
                    "No Courses",
                    systemImage: "books.vertical",
                    description: Text("Sync to load your enrolled courses.")
                )
            } else {
                gallery
            }
        }
        .navigationTitle("Courses")
    }

    private var gallery: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                ForEach(sections, id: \.tag) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        // Hide the header for the sole untagged shelf so an
                        // untagged library doesn't read as a stray "Other".
                        if sections.count > 1 || section.tag != nil {
                            shelfHeader(section.tag)
                        }

                        LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                            ForEach(section.courses) { course in
                                Button {
                                    onSelectCourse(course.id)
                                } label: {
                                    CourseCoverCard(
                                        course: course,
                                        syncState: appState.courseSyncStates[course.id],
                                        coverImage: appState.courseCoverImages[course.id]
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder
    private func shelfHeader(_ tag: FinderTag?) -> some View {
        HStack(spacing: 6) {
            if let tag {
                Circle()
                    .fill(tag.color.swiftUIColor)
                    .frame(width: 9, height: 9)
                Text(tag.name)
            } else {
                Text("Other")
            }
        }
        .font(.headline)
        .foregroundStyle(.secondary)
    }
}

/// A single generated "cover" for a course: a colored gradient tile with the
/// course's icon, its title, short name, and a small sync-status dot. A future
/// pass swaps the gradient for the course's Moodle overview image when present.
struct CourseCoverCard: View {
    let course: MoodleCourse
    var syncState: CourseSubscriptionState?
    var coverImage: NSImage?

    private var iconName: String {
        course.customIconName ?? "folder.fill"
    }

    private var title: String {
        if let custom = course.customFolderName,
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        return course.fullName
    }

    /// A stable, distinct color per course so the shelf reads like a bookshelf.
    private var coverColor: Color {
        let hue = Double(abs(course.id) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.72)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cover

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    Text(course.shortName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 4)

                    syncDot
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var cover: some View {
        // The rounded rectangle anchors the card's size via the aspect ratio.
        // The cover image lives in an overlay so its `scaledToFill` overflow
        // can't grow the layout, and `clipShape` masks it to the card bounds.
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [coverColor, coverColor.opacity(0.65)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let coverImage {
                    Image(nsImage: coverImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 40, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var syncDot: some View {
        switch syncState {
        case .syncing:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .synced, .stale:
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
        default:
            EmptyView()
        }
    }
}
