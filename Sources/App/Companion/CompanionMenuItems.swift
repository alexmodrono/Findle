import SwiftUI

struct CompanionMenuItems: View {
    let nodes: [CompanionNode]
    let openNode: (CompanionNode) -> Void

    var body: some View {
        ForEach(nodes, id: \.persistentID) { node in
            if node.children.isEmpty {
                Button(node.name, systemImage: node.symbolName) { openNode(node) }
                    .disabled(!node.canOpen)
            } else {
                Menu(node.name) {
                    if node.canOpen {
                        Button(node.openTitle) { openNode(node) }
                        Divider()
                    }
                    CompanionMenuItems(nodes: node.children, openNode: openNode)
                }
            }
        }
    }
}
