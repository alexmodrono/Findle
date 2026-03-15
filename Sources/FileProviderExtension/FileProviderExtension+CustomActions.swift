import FileProvider
import AppKit
import SharedDomain
import FoodlePersistence
import OSLog

extension FileProviderExtension: NSFileProviderCustomAction {

    private static let openInMoodleIdentifier = "es.amodrono.foodle.action.open-in-moodle"
    private static let copyMoodleLinkIdentifier = "es.amodrono.foodle.action.copy-moodle-link"
    private static let openCoursePageIdentifier = "es.amodrono.foodle.action.open-course-page"
    private static let keepDownloadedIdentifier = "es.amodrono.foodle.action.keep-downloaded"
    private static let removeDownloadIdentifier = "es.amodrono.foodle.action.remove-download"

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
            logger.error("Custom action failed: site not found for ID \(siteID, privacy: .public)")
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
            let url: URL
            if let localItem {
                url = MoodleURLBuilder.webURL(
                    baseURL: site.baseURL,
                    itemID: localItem.id,
                    courseID: localItem.courseID,
                    remoteID: localItem.remoteID,
                    isDirectory: localItem.isDirectory
                )
            } else {
                url = site.baseURL
            }
            logger.info("Opening in Moodle: \(url.absoluteString, privacy: .public)")
            NSWorkspace.shared.open(url)
            completionHandler(nil)

        case Self.copyMoodleLinkIdentifier:
            let url: URL
            if let localItem {
                url = MoodleURLBuilder.webURL(
                    baseURL: site.baseURL,
                    itemID: localItem.id,
                    courseID: localItem.courseID,
                    remoteID: localItem.remoteID,
                    isDirectory: localItem.isDirectory
                )
            } else {
                url = site.baseURL
            }
            logger.info("Copying Moodle link: \(url.absoluteString, privacy: .public)")
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(url.absoluteString, forType: .string)
            completionHandler(nil)

        case Self.openCoursePageIdentifier:
            let courseURL: URL
            if let localItem {
                courseURL = MoodleURLBuilder.courseURL(
                    baseURL: site.baseURL,
                    courseID: localItem.courseID
                )
            } else {
                courseURL = site.baseURL
            }
            logger.info("Opening course page: \(courseURL.absoluteString, privacy: .public)")
            NSWorkspace.shared.open(courseURL)
            completionHandler(nil)

        case Self.keepDownloadedIdentifier:
            do {
                for identifier in itemIdentifiers where identifier != .rootContainer {
                    try db.pinItemsRecursively(id: identifier.rawValue, isPinned: true)
                }
                logger.info("Pinned \(itemIdentifiers.count) items for offline access")
                signalChanges()
                completionHandler(nil)
            } catch {
                logger.error("Failed to pin items: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }

        case Self.removeDownloadIdentifier:
            do {
                for identifier in itemIdentifiers where identifier != .rootContainer {
                    try db.pinItemsRecursively(id: identifier.rawValue, isPinned: false)
                }
                logger.info("Unpinned \(itemIdentifiers.count) items")
                signalChanges()
                completionHandler(nil)
            } catch {
                logger.error("Failed to unpin items: \(error.localizedDescription, privacy: .public)")
                completionHandler(error)
            }

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
}
