import Foundation
import Observation

@MainActor
@Observable
final class CompanionPresentation {
    struct Row: Identifiable {
        let node: CompanionNode
        let depth: Int
        let parentID: String?
        var id: String { node.persistentID }
    }

    var mode: FinderPanelPlacement.Mode = .expanded
    var expandedWidth = FinderPanelPlacement.Mode.expanded.preferredSize.width
    var canExpand = true
    var attachedOnRight = true
    var title = "Findle"
    var shortTitle = "Findle"
    var subtitle = ""
    var hasCourse = false
    var isSyncing = false
    var canSync = false
    var lastSynced: Date?
    var sessionExpired = false
    var errorMessage: String?
    var emptyMessage = "Choose courses in Settings."
    private(set) var nodes: [CompanionNode] = []
    private(set) var expandedIDs = Set<String>()
    private(set) var hasSnapshot = false
    var selectedID: String?
    private var contextID: String?

    var toggleTitle: String { mode == .compact ? "Expand panel" : "Collapse panel" }
    var toggleSymbol: String { (mode == .compact) == attachedOnRight ? "sidebar.right" : "sidebar.left" }
    var toggleHelp: String {
        mode == .compact && !canExpand ? "Move Finder to make room for the expanded panel." : toggleTitle
    }
    var failureTitle: String { sessionExpired ? "Sign in again" : "Sync failed" }

    var visibleRows: [Row] {
        func rows(_ nodes: [CompanionNode], depth: Int, parentID: String?) -> [Row] {
            nodes.flatMap { node in
                [Row(node: node, depth: depth, parentID: parentID)] +
                    (expandedIDs.contains(node.persistentID) ? rows(node.children, depth: depth + 1, parentID: node.persistentID) : [])
            }
        }
        return rows(nodes, depth: 0, parentID: nil)
    }

    func replaceNodes(_ nodes: [CompanionNode], contextID: String) {
        let changedContext = self.contextID != contextID
        self.contextID = contextID
        self.nodes = nodes
        hasSnapshot = true
        if changedContext {
            selectedID = nil
            expandedIDs = Set(nodes.first(where: { !$0.children.isEmpty }).map { [$0.persistentID] } ?? [])
        } else {
            expandedIDs = expandedIDs.filter { node(for: $0) != nil }
            if let selectedID, !visibleRows.contains(where: { $0.id == selectedID }) { self.selectedID = nil }
        }
    }

    func node(for id: String) -> CompanionNode? {
        func find(in nodes: [CompanionNode]) -> CompanionNode? {
            for node in nodes {
                if node.persistentID == id { return node }
                if let match = find(in: node.children) { return match }
            }
            return nil
        }
        return find(in: nodes)
    }

    func toggleExpansion(_ node: CompanionNode) {
        guard !node.children.isEmpty else { return }
        if expandedIDs.remove(node.persistentID) == nil {
            expandedIDs.insert(node.persistentID)
        } else if let selectedID, !visibleRows.contains(where: { $0.id == selectedID }) {
            self.selectedID = node.persistentID
        }
    }

    func expandSelection() -> Bool {
        guard let selectedID, let node = node(for: selectedID), let child = node.children.first else { return false }
        if expandedIDs.contains(selectedID) { self.selectedID = child.persistentID }
        else { expandedIDs.insert(selectedID) }
        return true
    }

    func collapseSelection() -> Bool {
        guard let selectedID, let row = visibleRows.first(where: { $0.id == selectedID }) else { return false }
        if expandedIDs.contains(selectedID) { expandedIDs.remove(selectedID) }
        else if let parent = row.parentID { self.selectedID = parent }
        else { return false }
        return true
    }
}
