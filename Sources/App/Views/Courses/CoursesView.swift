// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import SharedDomain

struct CourseRow: View {
    let course: MoodleCourse
    let tags: [FinderTag]

    private var iconName: String {
        course.customIconName ?? "folder.fill"
    }

    private var primaryText: String {
        if let custom = course.customFolderName,
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return custom
        }
        return course.fullName
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryText)
                    .lineLimit(2)

                if course.customFolderName != nil &&
                   !(course.customFolderName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(course.fullName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
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
        } icon: {
            Image(systemName: iconName)
                .foregroundStyle(course.isSyncEnabled ? .secondary : .quaternary)
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
