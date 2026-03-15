// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import SharedDomain

struct CourseRow: View {
    let course: MoodleCourse
    let tags: [FinderTag]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: course.customIconName ?? "folder.fill")
                .foregroundStyle(course.isSyncEnabled ? .secondary : .quaternary)
                .imageScale(.large)

            VStack(alignment: .leading, spacing: 2) {
                if let custom = course.customFolderName,
                   !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(custom)
                        .lineLimit(2)
                    Text(course.fullName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(course.fullName)
                        .lineLimit(2)
                    Text(course.shortName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                if !tags.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            Circle()
                                .fill(tag.color.swiftUIColor)
                                .frame(width: 7, height: 7)
                        }
                    }
                }
            }
        }
        .opacity(course.isSyncEnabled ? 1.0 : 0.5)
        .padding(.vertical, 1)
    }
}

// MARK: - FinderTag.Color SwiftUI Extension

extension FinderTag.Color {
    var swiftUIColor: Color {
        switch self {
        case .none: .clear
        case .gray: .gray
        case .green: .green
        case .purple: .purple
        case .blue: .blue
        case .yellow: .yellow
        case .orange: .orange
        case .red: .red
        }
    }
}
