import AppKit
import SwiftUI

struct CompanionOutlineView: View {
    @Bindable var presentation: CompanionPresentation
    let openNode: (CompanionNode) -> Void
    let itemActions: CompanionItemActions
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        List(selection: $presentation.selectedID) {
            ForEach(presentation.visibleRows) { row in
                CompanionOutlineRow(row: row, presentation: presentation, itemURL: itemActions.url)
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
                if let itemID = node.itemID {
                    Button("Quick Look") { itemActions.quickLook(itemID) }
                    Button("Show in Finder") { itemActions.reveal(itemID) }
                    if let moodle = itemActions.moodleURL(itemID) {
                        Divider()
                        Button("Open in Moodle") { NSWorkspace.shared.open(moodle) }
                        Button("Copy Moodle Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(moodle.absoluteString, forType: .string)
                        }
                        Divider()
                        if node.isKept {
                            Button("Remove Download") { itemActions.removeDownload(itemID) }
                        } else {
                            Button("Keep Downloaded") { itemActions.keep(itemID) }
                        }
                    }
                }
            }
        } primaryAction: { selection in
            if let id = selection.first, let node = presentation.node(for: id) { openNode(node) }
        }
        .onKeyPress(.return, action: openSelection)
        .onKeyPress(.space) {
            guard let id = presentation.selectedID, let itemID = presentation.node(for: id)?.itemID else { return .ignored }
            itemActions.quickLook(itemID)
            return .handled
        }
        .onKeyPress(.rightArrow) { presentation.expandSelection() ? .handled : .ignored }
        .onKeyPress(.leftArrow) { presentation.collapseSelection() ? .handled : .ignored }
    }

    private func openSelection() -> KeyPress.Result {
        guard let id = presentation.selectedID, let node = presentation.node(for: id) else { return .ignored }
        openNode(node)
        return .handled
    }
}
