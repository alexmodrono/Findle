// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var updateController: UpdateController
    @Environment(\.openWindow) private var openWindow
    @StateObject private var loginItem = LoginItemController()
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("notifyOnSyncComplete") private var notifyOnSyncComplete = false
    @AppStorage("syncIntervalMinutes") private var syncInterval: Double = AppState.defaultSyncIntervalMinutes
    @AppStorage("syncOnLaunch") private var syncOnLaunch = true
    @AppStorage("enableVerboseLogging") private var verboseLogging = false

    @State private var confirmingSignOut = false
    @State private var showingDiagnostics = false

    var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Launch Findle at login",
                    // Drive the toggle from SMAppService.mainApp.status so the
                    // UI shows the actual registration state — the system can
                    // disable login items behind our back, and a stale
                    // UserDefaults bool would lie to the user.
                    isOn: Binding(
                        get: { loginItem.isEnabled },
                        set: { loginItem.setEnabled($0) }
                    )
                )
                if let error = loginItem.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Toggle("Show in menu bar", isOn: $showMenuBarIcon)
                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updateController.updater.automaticallyChecksForUpdates },
                        set: { updateController.updater.automaticallyChecksForUpdates = $0 }
                    )
                )
                Button("Check for Updates…") {
                    updateController.checkForUpdates()
                }
                .disabled(!updateController.canCheckForUpdates)
                if showMenuBarIcon {
                    Text("Findle stays accessible from the menu bar when you close the window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Notify when sync completes", isOn: $notifyOnSyncComplete)
            }

            Section {
                Button("Connect to AI…") {
                    openWindow(id: "mcp-connect")
                }
            } header: {
                Text("Assistant")
            } footer: {
                Text("Add Findle's tools to Claude, or set up access for ChatGPT.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Account") {
                if let account = appState.accounts.first, let site = appState.sites.first {
                    LabeledContent("Server", value: site.displayName)

                    LabeledContent("Address") {
                        Text(site.baseURL.host ?? site.baseURL.absoluteString)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }

                    if let version = site.capabilities.moodleRelease {
                        LabeledContent("Version", value: version)
                    }

                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(account.state.isConnected ? .green : .orange)
                            Text(account.state.isConnected ? "Connected" : "Disconnected")
                        }
                    }

                    Button("Sign Out", role: .destructive) {
                        confirmingSignOut = true
                    }
                    .confirmationDialog(
                        "Sign out of \(site.displayName)?",
                        isPresented: $confirmingSignOut
                    ) {
                        Button("Sign Out", role: .destructive) {
                            Task { await appState.logout() }
                        }
                    } message: {
                        Text("Your local course data and File Provider domain will be removed.")
                    }
                } else {
                    ContentUnavailableView(
                        "No Account Connected",
                        systemImage: "person.crop.circle.badge.xmark",
                        description: Text("Sign in to manage account settings.")
                    )
                }
            }

            Section("Sync") {
                Toggle("Sync when Findle launches", isOn: $syncOnLaunch)

                Picker("Sync cadence", selection: $syncInterval) {
                    Text("5 minutes").tag(5.0)
                    Text("15 minutes").tag(15.0)
                    Text("30 minutes").tag(30.0)
                    Text("1 hour").tag(60.0)
                    Text("2 hours").tag(120.0)
                    Text("Manual only").tag(0.0)
                }

                LabeledContent("Last sync") {
                    if let lastSync = appState.lastSyncDate {
                        Text(lastSync, format: .dateTime.month().day().hour().minute())
                    } else {
                        Text("Never")
                            .foregroundStyle(.secondary)
                    }
                }

                let enabledCount = appState.courses.filter(\.isSyncEnabled).count
                let totalCount = appState.courses.count
                LabeledContent("Courses") {
                    if enabledCount == totalCount {
                        Text("\(totalCount)")
                    } else {
                        Text("\(enabledCount) of \(totalCount) synced")
                    }
                }
            }

            Section {
                Toggle("Verbose logging", isOn: $verboseLogging)

                Button("Diagnostics…") {
                    showingDiagnostics = true
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Connection details, sync health, and maintenance actions (rebuild index, reset File Provider).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 480, idealWidth: 520)
        .sheet(isPresented: $showingDiagnostics) {
            NavigationStack {
                DiagnosticsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingDiagnostics = false }
                        }
                    }
            }
            .frame(minWidth: 540, minHeight: 480)
        }
        .onAppear {
            // System Settings > Login Items can flip our registration state
            // without notifying us, so re-read it whenever Settings reopens.
            loginItem.refresh()
        }
    }
}
