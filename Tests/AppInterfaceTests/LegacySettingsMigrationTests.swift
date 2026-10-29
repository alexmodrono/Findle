import Foundation
import Testing

struct LegacySettingsMigrationTests {
    @Test func existingPreferencesWinAndOldPreferencesAreImportedOnce() throws {
        let id = "es.amodrono.findle.migration-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: id))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: home)
        }
        let legacy = home.appendingPathComponent("Library/Containers/\(id)/Data/Library/Preferences/\(id).plist")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old: [String: Any] = ["currentSiteID": "old-site", "syncIntervalMinutes": 15.0]
        try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0).write(to: legacy)
        defaults.set(30.0, forKey: "syncIntervalMinutes")
        LegacySettingsMigration.run(defaults: defaults, bundleID: id, homeDirectory: home)
        #expect(defaults.string(forKey: "currentSiteID") == "old-site")
        #expect(defaults.double(forKey: "syncIntervalMinutes") == 30)
        #expect(defaults.bool(forKey: "appkitPreferencesMigrated"))
        defaults.removeObject(forKey: "currentSiteID")
        LegacySettingsMigration.run(defaults: defaults, bundleID: id, homeDirectory: home)
        #expect(defaults.string(forKey: "currentSiteID") == nil)
    }

    @Test func unreadablePreferencesCanBeRetried() throws {
        let id = "es.amodrono.findle.migration-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: id))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: id)
            try? FileManager.default.removeItem(at: home)
        }
        let legacy = home.appendingPathComponent("Library/Containers/\(id)/Data/Library/Preferences/\(id).plist")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid plist".utf8).write(to: legacy)
        LegacySettingsMigration.run(defaults: defaults, bundleID: id, homeDirectory: home)
        #expect(!defaults.bool(forKey: "appkitPreferencesMigrated"))
    }
}
