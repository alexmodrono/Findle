import SwiftUI

struct CompanionExpandedView: View {
    let presentation: CompanionPresentation
    let actions: CompanionActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(presentation.title)
                        .font(.title3).bold()
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(presentation.title)
                    Text(presentation.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                CompanionIconButton(title: presentation.toggleTitle, symbol: presentation.toggleSymbol, action: actions.toggleMode)
            }
            .padding(14)
            Divider().padding(.horizontal, 14)
            if presentation.nodes.isEmpty {
                ContentUnavailableView("No files yet", systemImage: "folder", description: Text(presentation.emptyMessage))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CompanionOutlineView(presentation: presentation, openNode: actions.openNode)
            }
            Divider().padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 8) {
                CompanionStatusView(presentation: presentation, compact: false, openSettings: actions.openSettings)
                HStack(spacing: 8) {
                    Button(action: actions.sync) {
                        Text("Sync now")
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                    }
                        .buttonStyle(CompanionButtonStyle())
                        .disabled(!presentation.canSync)
                    Spacer(minLength: 0)
                    CompanionIconButton(title: "Open in Moodle", symbol: "globe", action: actions.openMoodle)
                    CompanionIconButton(title: "Findle Settings", symbol: "gearshape", action: actions.openSettings)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}
