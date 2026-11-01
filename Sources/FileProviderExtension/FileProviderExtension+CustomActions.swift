// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import AppKit
import SharedDomain
import FindlePersistence
import OSLog

extension FileProviderExtension: NSFileProviderCustomAction {

    private static let openInMoodleIdentifier = BundleIdentifiers.actionOpenInMoodle
    private static let copyMoodleLinkIdentifier = BundleIdentifiers.actionCopyMoodleLink
    private static let openCoursePageIdentifier = BundleIdentifiers.actionOpenCoursePage
    private static let keepDownloadedIdentifier = BundleIdentifiers.actionKeepDownloaded
    private static let removeDownloadIdentifier = BundleIdentifiers.actionRemoveDownload
    private static let syncNowIdentifier = BundleIdentifiers.actionSyncNow

    func performAction(
        identifier actionIdentifier: NSFileProviderExtensionActionIdentifier,
        onItemsWithIdentifiers itemIdentifiers: [NSFileProviderItemIdentifier],
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)

        guard let db = database, let siteID = siteID else {
            logger.error("Custom action failed: no database or siteID")
            completionHandler(NSFileProviderError(.serverUnreachable))
            progress.completedUnitCount = 1
            return progress
        }

        guard let site = try? db.fetchSite(id: siteID) else {
            logger.error("Custom action failed: site not found for ID \(siteID, privacy: .private)")
            completionHandler(NSFileProviderError(.serverUnreachable))
            progress.completedUnitCount = 1
            return progress
        }

        guard let firstIdentifier = itemIdentifiers.first else {
            completionHandler(nil)
            progress.completedUnitCount = 1
            return progress
        }

        let localItem: LocalItem?
        if firstIdentifier == .rootContainer {
            localItem = nil
        } else if let item = try? db.fetchItem(id: firstIdentifier.rawValue) {
            localItem = item
        } else {
            completionHandler(NSFileProviderError(.noSuchItem))
            progress.completedUnitCount = 1
            return progress
        }

        switch actionIdentifier.rawValue {
        case Self.openInMoodleIdentifier:
            guard localItem?.isLocal != true else {
                completionHandler(NSFileProviderError(.cannotSynchronize))
                break
            }
            let url: URL
            if let localItem {
                url = MoodleURLBuilder.webURL(
                    baseURL: site.baseURL,
                    itemID: localItem.id,
                    courseID: localItem.courseID,
                    remoteID: localItem.remoteID,
                    isDirectory: localItem.isDirectory,
                    parentID: localItem.parentID
                )
            } else {
                url = site.baseURL
            }
            logger.info("Opening in Moodle: \(url.absoluteString, privacy: .private)")
            NSWorkspace.shared.open(url)
            completionHandler(nil)

        case Self.copyMoodleLinkIdentifier:
            guard localItem?.isLocal != true else {
                completionHandler(NSFileProviderError(.cannotSynchronize))
                break
            }
            let url: URL
            if let localItem {
                url = MoodleURLBuilder.webURL(
                    baseURL: site.baseURL,
                    itemID: localItem.id,
                    courseID: localItem.courseID,
                    remoteID: localItem.remoteID,
                    isDirectory: localItem.isDirectory,
                    parentID: localItem.parentID
                )
            } else {
                url = site.baseURL
            }
            logger.info("Copying Moodle link: \(url.absoluteString, privacy: .private)")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
            completionHandler(nil)

        case Self.openCoursePageIdentifier:
            guard localItem?.isLocal != true else {
                completionHandler(NSFileProviderError(.cannotSynchronize))
                break
            }
            let courseURL: URL
            if let localItem {
                courseURL = MoodleURLBuilder.courseURL(
                    baseURL: site.baseURL,
                    courseID: localItem.courseID
                )
            } else {
                courseURL = site.baseURL
            }
            logger.info("Opening course page: \(courseURL.absoluteString, privacy: .private)")
            NSWorkspace.shared.open(courseURL)
            completionHandler(nil)

        case Self.keepDownloadedIdentifier:
            // The new content policy makes the system download and keep the items.
            do {
                try DownloadRetention.keep(itemIdentifiers.filter { $0 != .rootContainer }.map(\.rawValue), database: db)
                logger.info("Kept \(itemIdentifiers.count) items downloaded")
                signalChanges()
                completionHandler(nil)
            } catch {
                logger.error("Failed to keep items downloaded: \(DiagnosticFailure(error).summary, privacy: .public)")
                completionHandler(error)
            }

        case Self.removeDownloadIdentifier:
            removeDownloads(
                itemIdentifiers.filter { $0 != .rootContainer }.map(\.rawValue),
                database: db, progress: progress, completionHandler: completionHandler
            )
            return progress

        case Self.syncNowIdentifier:
            // The extension has no sync engine of its own — it only reads rows
            // the app writes — so a manual refresh means waking the app up.
            logger.info("Sync Now requested from Finder")
            requestSyncFromApp()
            completionHandler(nil)

        default:
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError))
        }

        progress.completedUnitCount = 1
        return progress
    }

    private func signalChanges() {
        guard let manager = NSFileProviderManager(for: domain) else { return }
        manager.signalEnumerator(for: .workingSet) { _ in }
    }

    /// Unpin, then ask the system to evict. The action finishes once eviction
    /// has been attempted, so Finder reports a file that couldn't be removed.
    private func removeDownloads(
        _ ids: [String],
        database: Database,
        progress: Progress,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = ActionCompletion(progress: progress, handler: completionHandler)
        guard let manager = NSFileProviderManager(for: domain) else {
            completion.finish(NSFileProviderError(.providerNotFound))
            return
        }
        let log = logger
        nonisolated(unsafe) let unsafeManager = manager
        Task {
            do {
                try await DownloadRetention.remove(
                    ids, database: database,
                    signal: { try? await unsafeManager.signalEnumerator(for: .workingSet) },
                    evict: { try await unsafeManager.evictItem(identifier: NSFileProviderItemIdentifier($0)) }
                )
                log.info("Removed downloads for \(ids.count) items")
                completion.finish(nil)
            } catch {
                log.error("Failed to remove downloads: \(DiagnosticFailure(error).summary, privacy: .public)")
                completion.finish(error)
            }
        }
    }

    /// Ask the main app to sync immediately, launching it first if it isn't
    /// running. Without the launch step "Sync Now" would silently do nothing
    /// whenever the app is closed — which is precisely when content is stalest.
    private func requestSyncFromApp() {
        let appBundleID = BundleIdentifiers.prefix
        let notificationName = BundleIdentifiers.syncNowRequestNotification
        let log = logger

        // Covers the common case where the app is already listening.
        DarwinNotification.post(notificationName)

        Task { @MainActor in
            let isRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleIdentifier == appBundleID
            }
            guard !isRunning else { return }

            guard let appURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: appBundleID
            ) else {
                log.warning("Sync Now: could not locate \(appBundleID, privacy: .public) to launch")
                return
            }

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false

            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: appURL,
                    configuration: configuration
                )
                // A cold-launched app registers its observer during startup, so
                // the notification posted above arrived too early for it. Give
                // it a moment to come up, then post again.
                try? await Task.sleep(for: .seconds(2))
                DarwinNotification.post(notificationName)
            } catch {
                log.warning("Sync Now: failed to launch app: \(DiagnosticFailure(error).summary, privacy: .public)")
            }
        }
    }
}

/// Hands an action's completion handler to asynchronous work and calls it once.
private final class ActionCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: Progress
    private var handler: ((Error?) -> Void)?

    init(progress: Progress, handler: @escaping (Error?) -> Void) {
        self.progress = progress
        self.handler = handler
    }

    func finish(_ error: Error?) {
        lock.lock()
        let handler = self.handler
        self.handler = nil
        lock.unlock()
        progress.completedUnitCount = progress.totalUnitCount
        handler?(error)
    }
}
