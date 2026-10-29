import SwiftUI

struct CompanionOutlineRow: View {
    let row: CompanionPresentation.Row
    let presentation: CompanionPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            if !row.node.children.isEmpty {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(presentation.expandedIDs.contains(row.id) ? 90 : 0))
                        .frame(width: 14, height: 22)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(presentation.expandedIDs.contains(row.id) ? "Collapse" : "Expand") \(row.node.name)")
            } else {
                Color.clear.frame(width: 14, height: 1).accessibilityHidden(true)
            }
            Image(systemName: row.node.symbolName)
                .foregroundStyle(row.node.children.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(row.node.name)
                .font(.callout)
                .lineLimit(1)
                .help(row.node.name)
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .contentShape(.rect)
        .accessibilityElement(children: .contain)
    }

    private func toggle() {
        let animation: Animation? = !reduceMotion && CompanionMotion.isPointerInteraction ? .easeOut(duration: 0.16) : nil
        withAnimation(animation) { presentation.toggleExpansion(row.node) }
    }
}
