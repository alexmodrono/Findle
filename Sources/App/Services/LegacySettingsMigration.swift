import Foundation
import OSLog

/// Preserve preferences when the AppKit host moves out of App Sandbox.
enum LegacySettingsMigration {
    static func run(defaults: UserDefaults = .standard, bundleID: String? = Bundle.main.bundleIdentifier,
                    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        guard let bundleID, !defaults.bool(forKey: "appkitPreferencesMigrated") else { return }
        let url = homeDirectory
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                if let old = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    let existing = defaults.persistentDomain(forName: bundleID) ?? [:]
                    for (key, value) in old where existing[key] == nil { defaults.set(value, forKey: key) }
                }
            }
            defaults.set(true, forKey: "appkitPreferencesMigrated")
        } catch {
            Logger(subsystem: "es.amodrono.findle", category: "Migration")
                .error("Could not import sandbox preferences: \(error.localizedDescription, privacy: .public)")
        }
    }
}
