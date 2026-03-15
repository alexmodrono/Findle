import SwiftUI
import SharedDomain

struct AddTagPopover: View {
    @Binding var name: String
    @Binding var color: FinderTag.Color

    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                HStack(spacing: 6) {
                    ForEach(FinderTag.Color.allCases.filter { $0 != .none }, id: \.rawValue) { tagColor in
                        Button {
                            color = tagColor
                        } label: {
                            Circle()
                                .fill(tagColor.swiftUIColor)
                                .frame(width: 16, height: 16)
                                .overlay {
                                    if color == tagColor {
                                        Circle()
                                            .strokeBorder(.primary, lineWidth: 2)
                                    }
                                }
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
        .frame(width: 260)
    }
}
