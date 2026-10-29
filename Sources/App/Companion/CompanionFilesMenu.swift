import SwiftUI

struct CompanionFilesMenu: View {
    let nodes: [CompanionNode]
    let openNode: (CompanionNode) -> Void

    var body: some View {
        Menu {
            CompanionMenuItems(nodes: nodes, openNode: openNode)
        } label: {
            Label("Course files and activities", systemImage: "folder")
                .labelStyle(.iconOnly)
                .font(.body)
                .imageScale(.large)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(CompanionButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(nodes.isEmpty)
        .help("Course files and activities")
    }
}
