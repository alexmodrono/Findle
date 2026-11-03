// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI

/// The course's next deadlines in the expanded companion.
struct CompanionDeadlinesView: View {
    let deadlines: [CompanionDeadline]
    private let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Upcoming")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(deadlines.prefix(shown)) { deadline in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: deadline.symbolName)
                        .foregroundStyle(deadline.needsAction ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(deadline.name)
                            .font(.callout)
                            .lineLimit(1)
                        Text("\(deadline.dueText) · \(deadline.status)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .help(deadline.summary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(deadline.summary)
            }
            if deadlines.count > shown {
                Text("\(deadlines.count - shown) more later")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// The next deadline in the compact rail; the tooltip has the details.
struct CompanionNextDeadlineView: View {
    let deadline: CompanionDeadline

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "calendar.badge.clock")
                .foregroundStyle(deadline.needsAction ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .imageScale(.large)
            Text(deadline.due, format: .dateTime.weekday(.abbreviated))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 32)
        .help("Next: \(deadline.summary)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Next deadline: \(deadline.summary)")
    }
}
