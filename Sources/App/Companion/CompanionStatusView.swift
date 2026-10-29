import SwiftUI

struct CompanionStatusView: View {
    let presentation: CompanionPresentation
    let compact: Bool
    let openSettings: () -> Void
    @State private var showingError = false

    var body: some View {
        Group {
            if presentation.isSyncing {
                VStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("Syncing…")
                }
                .accessibilityElement(children: .combine)
            } else if let error = presentation.errorMessage {
                Button { showingError = true } label: {
                    Label(presentation.failureTitle, systemImage: "exclamationmark.triangle")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.borderless)
                .help(error)
                .popover(isPresented: $showingError, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(presentation.failureTitle).font(.headline)
                        Text(error).fixedSize(horizontal: false, vertical: true)
                        Button("Open Settings", action: openSettings)
                    }
                    .padding(16)
                    .frame(width: 260)
                }
            } else if let date = presentation.lastSynced {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    CompanionSyncTimestamp(date: date, now: context.date, compact: compact)
                }
            } else {
                Text("Not synced yet")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(compact ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: compact ? .center : .leading)
    }
}
