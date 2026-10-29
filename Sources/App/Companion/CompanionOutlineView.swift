import SwiftUI

struct CompanionOutlineView: View {
    @Bindable var presentation: CompanionPresentation
    let openNode: (CompanionNode) -> Void
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        List(selection: $presentation.selectedID) {
            ForEach(presentation.visibleRows) { row in
                CompanionOutlineRow(row: row, presentation: presentation)
                    .tag(row.id)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 30)
        .focusable()
        .focused($hasKeyboardFocus)
        .onChange(of: presentation.selectedID) { _, selection in
            if selection != nil { hasKeyboardFocus = true }
        }
        .accessibilityLabel(presentation.hasCourse ? "Course contents" : "Synced courses")
        .contextMenu(forSelectionType: String.self) { selection in
            if let id = selection.first, let node = presentation.node(for: id) {
                Button(node.openTitle) { openNode(node) }
            }
        } primaryAction: { selection in
            if let id = selection.first, let node = presentation.node(for: id) { openNode(node) }
        }
        .onKeyPress(.return, action: openSelection)
        .onKeyPress(.rightArrow) { presentation.expandSelection() ? .handled : .ignored }
        .onKeyPress(.leftArrow) { presentation.collapseSelection() ? .handled : .ignored }
    }

    private func openSelection() -> KeyPress.Result {
        guard let id = presentation.selectedID, let node = presentation.node(for: id) else { return .ignored }
        openNode(node)
        return .handled
    }
}
