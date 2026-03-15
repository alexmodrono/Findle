import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var confirmingResetProvider = false
    @State private var confirmingReauth = false

    var body: some View {
        Form {
            Section("Connection") {
                if let account = appState.accounts.first {
                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Image(systemName: account.state.isConnected
                                  ? "circle.fill" : "circle.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(account.state.isConnected ? .green : .orange)
                            Text(account.state.isConnected ? "Connected" : "Disconnected")
                        }
                    }

                    LabeledContent("Account ID") {
                        Text(String(account.id.prefix(8)) + "…")
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                }

                if let site = appState.sites.first {
                    LabeledContent("Server", value: site.displayName)

                    LabeledContent("Host") {
                        Text(site.baseURL.host ?? site.baseURL.absoluteString)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    if let version = site.capabilities.moodleRelease {
                        LabeledContent("Moodle", value: version)
                    }
                }

                LabeledContent("Courses", value: "\(appState.courses.count)")
            }

            Section("Sync Health") {
                LabeledContent("State") {
                    HStack(spacing: 4) {
                        switch appState.syncStatus {
                        case .idle:
                            Text("Idle")
                                .foregroundStyle(.secondary)
                        case .syncing(let progress):
                            ProgressView(value: progress)
                                .frame(width: 60)
                            Text("Syncing \(Int(progress * 100))%")
                        case .completed:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Completed")
                        case .error:
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Error")
                        }
                    }
                }

                LabeledContent("Last sync") {
                    if let lastSync = appState.lastSyncDate {
                        Text(lastSync, format: .dateTime.month().day().hour().minute())
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }

                if case .error(let message) = appState.syncStatus {
                    LabeledContent("Error") {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if let error = appState.errorMessage {
                Section("Last Error") {
                    Text(error)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Maintenance") {
                Button("Rebuild Index") {
                    Task { await appState.rebuildIndex() }
                }

                Button("Reset File Provider Domain") {
                    confirmingResetProvider = true
                }
                .confirmationDialog(
                    "Reset File Provider?",
                    isPresented: $confirmingResetProvider
                ) {
                    Button("Reset", role: .destructive) {
                        Task { await appState.resetProvider() }
                    }
                } message: {
                    Text("This will remove and re-register the File Provider domain. Downloaded files will need to be re-synced.")
                }

                Button("Export Diagnostics", action: exportDiagnostics)

                Button("Re-authenticate", role: .destructive) {
                    confirmingReauth = true
                }
                .confirmationDialog(
                    "Re-authenticate?",
                    isPresented: $confirmingReauth
                ) {
                    Button("Sign Out and Re-authenticate", role: .destructive) {
                        Task { await appState.reauthenticate() }
                    }
                } message: {
                    Text("You will be signed out and need to sign in again.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.json]
        panel.nameFieldStringValue = "findle-diagnostics-\(Date().ISO8601Format()).json"

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
