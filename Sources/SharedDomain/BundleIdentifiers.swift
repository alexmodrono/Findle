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

    /// Base identifier prefix (e.g., `es.amodrono.findle` or `es.amodrono.findle.nightly`).
    public static let prefix: String = {
        guard let id = Bundle.main.bundleIdentifier else { return "es.amodrono.findle" }
        // In the File Provider extension process, strip the ".file-provider" suffix.
        if id.hasSuffix(".file-provider") {
            return String(id.dropLast(".file-provider".count))
        }
        return id
    }()

    /// Whether this is a Nightly build.
    ///
    /// Nightly and Release are separate applications that must coexist without
    /// touching each other's data. Everything below that could otherwise collide
    /// — the Finder mount name, the MCP port, the Claude config key — is keyed
    /// off this rather than off a build flag, so the File Provider extension
    /// (whose `prefix` is derived the same way) agrees with the app it ships in.
    public static let isNightly = prefix.hasSuffix(".nightly")

    /// User-facing product name, matching `PRODUCT_NAME` for each config.
    public static let appDisplayName = isNightly ? "Findle Nightly" : "Findle"

    /// App group identifier for shared container access.
    public static let appGroup = "group.\(prefix)"

    /// Loopback port for the MCP helper's HTTP transport. Release and Nightly
    /// need different ports or whichever launches second fails to bind.
    public static let mcpPort: UInt16 = isNightly ? 8766 : 8765

    /// Key this build uses under `mcpServers` in an assistant's JSON config.
    /// Distinct per build so installing Nightly can't clobber the entry that
    /// points at the release app — and so removing one leaves the other intact.
    public static let mcpServerKey = isNightly ? "findle-nightly" : "findle"

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
    public static let actionSyncNow = "\(prefix).action.sync-now"

    // MARK: - Cross-Process Notifications

    /// Darwin notification the File Provider extension posts to ask the main app
    /// to sync immediately. Darwin notifications carry no payload and cross
    /// sandbox boundaries without any shared-container or entitlement setup,
    /// which the extension's XPC-hosted process needs.
    public static let syncNowRequestNotification = "\(prefix).sync-now-requested"
}
