import SwiftUI
import SharedDomain

struct DiagnosticsView: View {
    @EnvironmentObject var appState: AppState
    @State private var isExporting = false
    @State private var exportURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Button {
                    appState.currentScreen = .courses
                } label: {
                    Label("Back to Courses", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)

                Spacer()
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Status Section
                    GroupBox("Connection Status") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let account = appState.accounts.first {
                                statusRow("Account", value: account.state.isConnected ? "Connected" : "Disconnected")
                                statusRow("Account ID", value: String(account.id.prefix(8)) + "...")
                            }
                            if let site = appState.sites.first {
                                statusRow("Server", value: site.baseURL.host ?? "Unknown")
                                if let version = site.capabilities.moodleRelease {
                                    statusRow("Moodle Version", value: version)
                                }
                            }
                            statusRow("Courses", value: "\(appState.courses.count)")
                        }
                        .padding(8)
                    }

                    // Sync Status Section
                    GroupBox("Sync Status") {
                        VStack(alignment: .leading, spacing: 8) {
                            switch appState.syncStatus {
                            case .idle:
                                statusRow("Status", value: "Idle")
                            case .syncing(let progress):
                                statusRow("Status", value: "Syncing (\(Int(progress * 100))%)")
                            case .completed:
                                statusRow("Status", value: "Completed")
                            case .error(let message):
                                statusRow("Status", value: "Error")
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            if let lastSync = appState.lastSyncDate {
                                statusRow("Last Sync", value: lastSync.formatted(.dateTime))
                            }
                        }
                        .padding(8)
                    }

                    // Actions
                    GroupBox("Actions") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button("Rebuild Index") {
                                Task { await appState.rebuildIndex() }
                            }

                            Button("Reset File Provider Domain") {
                                Task { await appState.resetProvider() }
                            }

                            Button("Export Diagnostics") {
                                exportDiagnostics()
                            }

                            Divider()

                            Button("Re-authenticate") {
                                appState.currentScreen = .onboarding
                            }
                        }
                        .padding(8)
                    }

                    if let error = appState.errorMessage {
                        GroupBox("Last Error") {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)
            Text(value)
                .fontWeight(.medium)
        }
        .font(.subheadline)
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "foodle-diagnostics-\(Date().ISO8601Format()).json"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let diagnostics: [String: Any] = [
                "version": "1.0.0",
                "timestamp": Date().ISO8601Format(),
                "accounts_count": appState.accounts.count,
                "courses_count": appState.courses.count,
                "sync_status": String(describing: appState.syncStatus),
                "last_sync": appState.lastSyncDate?.ISO8601Format() ?? "never"
            ]

            if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: .prettyPrinted) {
                try? data.write(to: url)
            }
        }
    }
}
