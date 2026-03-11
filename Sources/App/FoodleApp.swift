import SwiftUI

@main
struct FoodleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 800, height: 600)

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
