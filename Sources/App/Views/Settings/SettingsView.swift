// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("notifyOnSyncComplete") private var notifyOnSyncComplete = false
    @AppStorage("syncIntervalMinutes") private var syncInterval: Double = 30
    @AppStorage("syncOnLaunch") private var syncOnLaunch = true
    @AppStorage("enableVerboseLogging") private var verboseLogging = false

    @State private var confirmingSignOut = false
    @State private var confirmingResetProvider = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch Findle at login", isOn: $launchAtLogin)
                Toggle("Show in menu bar", isOn: $showMenuBarIcon)
                if showMenuBarIcon {
                    Text("Findle stays accessible from the menu bar when you close the window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Notify when sync completes", isOn: $notifyOnSyncComplete)
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

            Section("Advanced") {
                Toggle("Verbose logging", isOn: $verboseLogging)

                Button("Rebuild Index") {
                    Task { await appState.rebuildIndex() }
                }

                Button("Reset File Provider") {
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
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .frame(minWidth: 480, idealWidth: 520)
    }
}
