// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import SharedDomain

struct CourseDetailHeader: View {
    let course: MoodleCourse

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            courseIcon

            VStack(alignment: .leading, spacing: 6) {
                Text(course.fullName)
                    .font(.title2)
                    .bold()
                    .textSelection(.enabled)

                Text(course.shortName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                metadataRow
            }
        }
        .padding(.vertical, 4)
    }

    private var courseIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(.blue.gradient.opacity(0.12))
                .frame(width: 52, height: 52)

            Image(systemName: course.customIconName ?? "folder.fill")
                .font(.title2)
                .foregroundStyle(.blue)
        }
        .accessibilityHidden(true)
    }

    private var metadataRow: some View {
        HStack(spacing: 8) {
            visibilityBadge

            if let dateRange = formattedDateRange {
                Text("·")
                    .foregroundStyle(.quaternary)

                Text(dateRange)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 2)
    }

    private var visibilityBadge: some View {
        Label(
            course.visible ? "Visible" : "Hidden",
            systemImage: course.visible ? "eye.fill" : "eye.slash.fill"
        )
        .font(.subheadline)
        .foregroundStyle(course.visible ? .green : .orange)
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
}
