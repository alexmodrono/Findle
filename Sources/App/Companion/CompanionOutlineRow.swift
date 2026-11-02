import SwiftUI

struct CompanionOutlineRow: View {
    let row: CompanionPresentation.Row
    let presentation: CompanionPresentation
    let itemURL: @Sendable (String) async -> URL?
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
            if row.node.isNew {
                Circle()
                    .fill(.tint)
                    .frame(width: 7, height: 7)
                    .help("New since your last visit")
                    .accessibilityLabel("New")
            }
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .contentShape(.rect)
        .onDrag(dragProvider)
        .accessibilityElement(children: .contain)
    }

    /// Drags the item itself into Mail, a document or the Desktop. Its Finder
    /// location is looked up when the drop asks for it; a file in the cloud
    /// downloads as the receiver reads it.
    private func dragProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        guard let itemID = row.node.itemID else { return provider }
        provider.suggestedName = row.node.name
        let resolve = itemURL
        provider.registerObject(ofClass: NSURL.self, visibility: .all) { completion in
            Task {
                let url = await resolve(itemID)
                completion(url as NSURL?, url == nil ? CocoaError(.fileNoSuchFile) : nil)
            }
            return nil
        }
        return provider
    }

    private func toggle() {
        let animation: Animation? = !reduceMotion && CompanionMotion.isPointerInteraction ? .easeOut(duration: 0.16) : nil
        withAnimation(animation) { presentation.toggleExpansion(row.node) }
    }
}
