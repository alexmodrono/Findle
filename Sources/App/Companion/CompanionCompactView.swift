import SwiftUI

struct CompanionCompactView: View {
    let presentation: CompanionPresentation
    let actions: CompanionActions

    var body: some View {
        VStack(spacing: 10) {
            CompanionIconButton(title: presentation.toggleTitle, symbol: presentation.toggleSymbol, action: actions.toggleMode)
                .disabled(!presentation.canExpand)
                .help(presentation.toggleHelp)
            Text(presentation.shortTitle)
                .font(.caption).bold()
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .help(presentation.title)
                .accessibilityLabel(presentation.title)
            Divider().padding(.horizontal, 14)
            VStack(spacing: 6) {
                CompanionIconButton(title: "Sync now", symbol: "arrow.triangle.2.circlepath", action: actions.sync)
                    .disabled(!presentation.canSync)
                CompanionIconButton(title: "Open in Moodle", symbol: "globe", action: actions.openMoodle)
                CompanionFilesMenu(nodes: presentation.nodes, openNode: actions.openNode)
            }
            Spacer(minLength: 0)
            CompanionStatusView(presentation: presentation, compact: true, openSettings: actions.openSettings)
            CompanionIconButton(title: "Findle Settings", symbol: "gearshape", action: actions.openSettings)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
    }
}
