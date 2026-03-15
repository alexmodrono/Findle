// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import SharedDomain

struct AddTagPopover: View {
    @Binding var name: String
    @Binding var color: FinderTag.Color

    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Tag")
                .font(.headline)

            TextField("Tag name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onAdd()
                    }
                }

            LabeledContent("Color") {
                HStack(spacing: 8) {
                    ForEach(FinderTag.Color.allCases.filter { $0 != .none }, id: \.rawValue) { tagColor in
                        Button {
                            color = tagColor
                        } label: {
                            Circle()
                                .fill(tagColor.swiftUIColor)
                                .frame(width: 18, height: 18)
                                .overlay {
                                    if color == tagColor {
                                        Circle()
                                            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                                            .frame(width: 12, height: 12)
                                    }
                                }
                                .shadow(color: tagColor.swiftUIColor.opacity(color == tagColor ? 0.4 : 0), radius: 3)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(tagColor.displayName)
                        .accessibilityAddTraits(color == tagColor ? .isSelected : [])
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add", action: onAdd)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 280)
    }
}
