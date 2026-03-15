import SwiftUI
import SharedDomain

struct TagBadge: View {
    let tag: FinderTag
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tag.color.swiftUIColor)
                .frame(width: 8, height: 8)

            Text(tag.name)
                .font(.callout)

            Button("Remove tag", systemImage: "xmark", action: onRemove)
                .labelStyle(.iconOnly)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }
}
