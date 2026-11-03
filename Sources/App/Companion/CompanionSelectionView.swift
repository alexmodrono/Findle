// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI

/// The Finder selection's Moodle context: where it sits, when it was posted and
/// changed, whether it is on this Mac, and what can be done with it.
struct CompanionSelectionView: View {
    let selection: CompanionSelection
    let actions: CompanionActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(selection.name)
                .font(.headline)
                .lineLimit(2)
                .help(selection.name)
            if !selection.place.isEmpty {
                Text(selection.placeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let posted = selection.posted {
                    detail("Posted", posted.formatted(date: .abbreviated, time: .shortened))
                }
                if let changed = selection.changed, changed != selection.posted {
                    detail("Changed", changed.formatted(date: .abbreviated, time: .shortened))
                }
                Label(selection.downloadText, systemImage: selection.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if selection.isFromMoodle {
                HStack(spacing: 8) {
                    Button("Open in Moodle") { actions.openSelectionInMoodle(selection) }
                        .disabled(selection.moodleURL == nil)
                    if selection.isKept {
                        Button("Remove Download") { actions.removeSelectionDownload(selection) }
                    } else {
                        Button("Keep Offline") { actions.keepSelection(selection) }
                    }
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selected in Finder: \(selection.name)")
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .font(.caption)
    }
}
