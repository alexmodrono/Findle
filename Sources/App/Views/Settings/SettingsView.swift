import SwiftUI
import SharedDomain

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = SettingsTab.general

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case account = "Account"
        case sync = "Sync"
        case advanced = "Advanced"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)

            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.circle") }
                .tag(SettingsTab.account)

            SyncSettingsTab()
                .tabItem { Label("Sync", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.sync)

            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "wrench") }
                .tag(SettingsTab.advanced)
        }
        .frame(width: 500, height: 350)
        .environmentObject(appState)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("notifyOnSyncComplete") private var notifyOnSyncComplete = false

    var body: some View {
        Form {
            Toggle("Launch Foodle at login", isOn: $launchAtLogin)
            Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
            Toggle("Notify when sync completes", isOn: $notifyOnSyncComplete)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Account

struct AccountSettingsTab: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Form {
            if let account = appState.accounts.first,
               let site = appState.sites.first {
                Section("Connected Account") {
                    LabeledContent("Server", value: site.displayName)
                    LabeledContent("URL", value: site.baseURL.host ?? "")
                    if let version = site.capabilities.moodleRelease {
                        LabeledContent("Version", value: version)
                    }
                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(account.state.isConnected ? .green : .red)
                                .frame(width: 8, height: 8)
                            Text(account.state.isConnected ? "Connected" : "Disconnected")
                        }
                    }
                }

                Section {
                    Button("Sign Out", role: .destructive) {
                        Task { await appState.logout() }
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Account",
                    systemImage: "person.crop.circle.badge.xmark",
                    description: Text("No account is connected.")
                )
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Sync

struct SyncSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("syncIntervalMinutes") private var syncInterval: Double = 30
    @AppStorage("syncOnLaunch") private var syncOnLaunch = true

    var body: some View {
        Form {
            Section("Automatic Sync") {
                Toggle("Sync on launch", isOn: $syncOnLaunch)

                HStack {
                    Text("Sync interval")
                    Spacer()
                    Picker("", selection: $syncInterval) {
                        Text("15 minutes").tag(15.0)
                        Text("30 minutes").tag(30.0)
                        Text("1 hour").tag(60.0)
                        Text("2 hours").tag(120.0)
                        Text("Manual only").tag(0.0)
                    }
                    .frame(width: 160)
                }
            }

            Section("Status") {
                if let lastSync = appState.lastSyncDate {
                    LabeledContent("Last sync", value: lastSync, format: .dateTime)
                } else {
                    LabeledContent("Last sync", value: "Never")
                }
                LabeledContent("Courses", value: "\(appState.courses.count)")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Advanced

struct AdvancedSettingsTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("enableVerboseLogging") private var verboseLogging = false

    var body: some View {
        Form {
            Section("Logging") {
                Toggle("Enable verbose logging", isOn: $verboseLogging)
            }

            Section("Maintenance") {
                Button("Rebuild Index") {
                    Task { await appState.rebuildIndex() }
                }

                Button("Reset File Provider") {
                    Task { await appState.resetProvider() }
                }
            }

            Section {
                Button("Open Diagnostics") {
                    appState.currentScreen = .diagnostics
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
