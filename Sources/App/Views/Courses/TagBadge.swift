// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import SharedDomain

struct TagBadge: View {
    let tag: FinderTag
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tag.color.swiftUIColor)
                .frame(width: 8, height: 8)

            Text(tag.name)
                .font(.subheadline)

            Button("Remove tag", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .imageScale(.small)
                .foregroundStyle(.tertiary)
                .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.fill.tertiary, in: Capsule())
    }
}
