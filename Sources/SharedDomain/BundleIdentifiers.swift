// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// Centralized identifiers that automatically vary between Release and Nightly builds.
///
/// All values are derived from `Bundle.main.bundleIdentifier` at runtime, so the
/// correct values are used automatically based on which scheme built the app.
public enum BundleIdentifiers {

    /// Base identifier prefix (e.g., `es.amodrono.foodle` or `es.amodrono.foodle.nightly`).
    public static let prefix: String = {
        guard let id = Bundle.main.bundleIdentifier else { return "es.amodrono.foodle" }
        // In the File Provider extension process, strip the ".file-provider" suffix.
        if id.hasSuffix(".file-provider") {
            return String(id.dropLast(".file-provider".count))
        }
        return id
    }()

    /// App group identifier for shared container access.
    public static let appGroup = "group.\(prefix)"

    /// Keychain service name for credential storage.
    public static let keychainService = prefix

    /// Build a File Provider domain identifier for a given site.
    public static func fileProviderDomainID(siteID: String) -> String {
        "\(prefix).domain.\(siteID)"
    }

    /// Prefix for Spotlight domain/unique identifiers.
    public static let spotlightPrefix = prefix

    // MARK: - File Provider Custom Action Identifiers

    public static let actionOpenInMoodle = "\(prefix).action.open-in-moodle"
    public static let actionCopyMoodleLink = "\(prefix).action.copy-moodle-link"
    public static let actionOpenCoursePage = "\(prefix).action.open-course-page"
    public static let actionKeepDownloaded = "\(prefix).action.keep-downloaded"
    public static let actionRemoveDownload = "\(prefix).action.remove-download"
}
