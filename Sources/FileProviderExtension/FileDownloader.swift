// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import FileProvider
import SharedDomain
import FindleNetworking
import FindlePersistence
import OSLog

/// Handles file downloads for the File Provider extension.
/// Uses URLSession's callback API so File Provider completion handlers stay in the
/// framework's callback world instead of crossing Swift concurrency executors.
enum FileDownloader {
    private static let logger = Logger(subsystem: "es.amodrono.findle.file-provider", category: "Download")

    /// Reset an item to `.placeholder` after a failed download so the next
    /// fetch retries cleanly. A failure here would otherwise strand the item in
    /// `.downloading`, so log it instead of swallowing it silently.
    private static func resetToPlaceholder(item: LocalItem, database: Database) {
        do {
            _ = try database.updateDownloadState(for: item, state: .placeholder, onlyIfDownloading: true)
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .download, outcome: .failed, failure: DiagnosticFailure(error)))
            logger.error("Failed to reset \(item.id, privacy: .private) to placeholder after download failure: \(DiagnosticFailure(error).summary, privacy: .public)")
        }
    }

    /// Converts a URLSession failure into the error Finder expects. Network
    /// failures are transient; cancellation is not an error to surface.
    fileprivate static func mapTransportError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        if urlError.code == .cancelled {
            return CocoaError(.userCancelled)
        }
        return NSFileProviderError(.serverUnreachable)
    }

    static func startDownload(
        item: LocalItem,
        database: Database,
        progress: Progress,
        temporaryDirectory: URL? = nil,
        tokenReader: (String) throws -> String? = { try KeychainManager.shared.retrieveToken(forAccount: $0) },
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) throws {
        let completionBridge = FileDownloadCompletionBridge(
            progress: progress,
            completionHandler: completionHandler
        )

        guard !progress.isCancelled else { throw CocoaError(.userCancelled) }
        let destinationURL = DownloadPublication.destination(for: item, in: temporaryDirectory)
        if let data = try MoodleWebLocation.data(for: item) {
            let updated: LocalItem
            do {
                updated = try DownloadPublication.publishGenerated(
                    data, item: item, database: database, destination: destinationURL, progress: progress)
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain || failure.domain == NSFileProviderErrorDomain {
                    throw error
                }
                DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                    process: .fileProvider, operation: .download, outcome: .failed, failure: DiagnosticFailure(error)))
                throw NSFileProviderError(.serverUnreachable)
            }
            completionBridge.succeed(url: destinationURL, item: FileProviderItem(localItem: updated))
            return
        }

        guard let remoteURL = item.remoteURL else {
            throw NSFileProviderError(.cannotSynchronize)
        }

        // Establish trust from the item's persisted site before touching Keychain.
        let storedSite: MoodleSite?
        do {
            storedSite = try database.fetchSite(id: item.siteID)
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .download, outcome: .failed, failure: DiagnosticFailure(error)))
            throw NSFileProviderError(.serverUnreachable)
        }
        guard let site = storedSite else {
            throw NSFileProviderError(.serverUnreachable)
        }
        let origin: AuthenticatedRequestOrigin
        do {
            origin = try AuthenticatedRequestOrigin(site: site)
            try origin.validate(remoteURL)
        } catch {
            throw CocoaError(.fileReadNoPermission)
        }

        let tokenAccountID: String
        do {
            tokenAccountID = try database.fetchAccounts().first(where: { $0.siteID == item.siteID })?.id ?? item.siteID
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .download, outcome: .failed, failure: DiagnosticFailure(error)))
            logger.error("Could not read accounts for download of \(item.id, privacy: .private): \(DiagnosticFailure(error).summary, privacy: .public)")
            throw NSFileProviderError(.serverUnreachable)
        }

        let storedToken: String?
        do {
            storedToken = try tokenReader(tokenAccountID)
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .authentication, outcome: .failed, failure: DiagnosticFailure(error)))
            // A keychain failure is not a sign-out. Report it as transient.
            logger.error("Keychain read failed for download of \(item.id, privacy: .private): \(DiagnosticFailure(error).summary, privacy: .public)")
            throw NSFileProviderError(.serverUnreachable)
        }
        guard let tokenString = storedToken else {
            throw NSFileProviderError(.notAuthenticated)
        }

        let authenticatedRequest = try origin.fileRequest(url: remoteURL, token: AuthToken(token: tokenString))
        do {
            guard try database.updateDownloadState(for: item, state: .downloading) != nil else {
                throw NSFileProviderError(.versionNoLongerAvailable)
            }
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .download, outcome: .failed, failure: DiagnosticFailure(error)))
            logger.error("Could not mark \(item.id, privacy: .private) as downloading: \(DiagnosticFailure(error).summary, privacy: .public)")
            throw NSFileProviderError(.serverUnreachable)
        }

        DownloadCoordinator.shared.start(
            request: authenticatedRequest,
            origin: origin,
            item: item,
            database: database,
            destination: destinationURL,
            progress: progress,
            bridge: completionBridge
        )
    }

    fileprivate static func resetToPlaceholderIfNeeded(item: LocalItem, database: Database) {
        resetToPlaceholder(item: item, database: database)
    }

}

/// Runs File Provider materializations on one shared delegate-backed session.
///
/// A delegate is what makes byte-level progress observable: the completion-handler
/// form of `downloadTask` reports nothing until it finishes, so Finder showed an
/// indeterminate spinner for the whole transfer — a 75 MB lecture PDF looked
/// identical to a hung download. Sharing a single session (rather than creating
/// one per file) preserves connection reuse to the Moodle host.
final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared: DownloadCoordinator = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 30 * 60
        return DownloadCoordinator(configuration: configuration)
    }()

    private struct Context {
        let attemptID: UUID
        let relatedAttemptID: UUID?
        let item: LocalItem
        let database: Database
        let destination: URL
        let progress: Progress
        let bridge: FileDownloadCompletionBridge
        let redirectDelegate: AuthenticatedRedirectDelegate
        /// Moodle reports each file's size in the course contents, so we can
        /// still show a real bar when a response omits `Content-Length`.
        let expectedSize: Int64

        func record(_ outcome: DiagnosticEvent.Outcome, error: (any Error)? = nil) {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                attemptID: attemptID, relatedAttemptID: relatedAttemptID, process: .fileProvider,
                operation: .download, outcome: outcome, failure: error.map(DiagnosticFailure.init)
            ))
        }
    }

    private let logger = Logger(subsystem: "es.amodrono.findle.file-provider", category: "Download")
    private let lock = NSLock()
    private var contexts: [Int: Context] = [:]

    // Initialize before the singleton is published. A lazy property can race
    // on concurrent first downloads and produce sessions with colliding task IDs.
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        precondition(configuration.identifier == nil, "Authenticated downloads require redirect callbacks")
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// An owner of a nonshared coordinator must release URLSession's delegate
    /// retention when finished. The production singleton lives for the process.
    func invalidate() {
        session.invalidateAndCancel()
    }

    func start(
        request: URLRequest,
        origin: AuthenticatedRequestOrigin,
        item: LocalItem,
        database: Database,
        destination: URL,
        progress: Progress,
        bridge: FileDownloadCompletionBridge
    ) {
        let task = session.downloadTask(with: request)
        let recentHostAttempt = (try? DiagnosticJournal(databasePath: database.filePath)?.read())?
            .last(where: { $0.process == .app && $0.operation == .sync })?.attemptID
        let context = Context(
            attemptID: UUID(),
            relatedAttemptID: recentHostAttempt,
            item: item,
            database: database,
            destination: destination,
            progress: progress,
            bridge: bridge,
            redirectDelegate: AuthenticatedRedirectDelegate(origin: origin),
            expectedSize: item.fileSize
        )

        // Register before `resume()` so no delegate callback can arrive first.
        lock.lock()
        contexts[task.taskIdentifier] = context
        lock.unlock()

        context.record(.started)

        let taskID = task.taskIdentifier
        progress.cancellationHandler = { [weak self] in
            task.cancel()
            guard let context = self?.removeContext(for: taskID) else { return }
            context.bridge.fail(CocoaError(.userCancelled))
            context.record(.cancelled, error: CocoaError(.userCancelled))
            FileDownloader.resetToPlaceholderIfNeeded(item: context.item, database: context.database)
        }
        if progress.isCancelled {
            task.cancel()
            if let context = removeContext(for: taskID) {
                context.bridge.fail(CocoaError(.userCancelled))
                FileDownloader.resetToPlaceholderIfNeeded(item: context.item, database: context.database)
            }
        } else {
            task.resume()
        }
    }

    private func context(for taskIdentifier: Int) -> Context? {
        lock.lock()
        defer { lock.unlock() }
        return contexts[taskIdentifier]
    }

    @discardableResult
    private func removeContext(for taskIdentifier: Int) -> Context? {
        lock.lock()
        let context = contexts.removeValue(forKey: taskIdentifier)
        lock.unlock()
        context?.progress.cancellationHandler = nil
        return context
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let context = context(for: task.taskIdentifier) else {
            completionHandler(nil)
            return
        }
        context.redirectDelegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                            newRequest: request, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let context = context(for: downloadTask.taskIdentifier) else { return }

        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : context.expectedSize
        // With no size from either source, leave the caller's placeholder units
        // alone rather than reporting a fraction we'd be inventing.
        guard expected > 0 else { return }

        context.progress.totalUnitCount = expected
        context.progress.completedUnitCount = min(totalBytesWritten, expected)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let context = context(for: downloadTask.taskIdentifier) else { return }

        do {
            guard !context.redirectDelegate.didRejectRedirect else { throw CocoaError(.fileReadNoPermission) }
            let updatedItem = try DownloadPublication.publish(
                item: context.item, database: context.database,
                response: downloadTask.response as? HTTPURLResponse, source: location,
                destination: context.destination, progress: context.progress)

            removeContext(for: downloadTask.taskIdentifier)
            context.record(.succeeded)
            context.bridge.succeed(
                url: context.destination,
                item: FileProviderItem(localItem: updatedItem)
            )
        } catch {
            context.record(.failed, error: error)
            removeContext(for: downloadTask.taskIdentifier)
            FileDownloader.resetToPlaceholderIfNeeded(item: context.item, database: context.database)
            context.bridge.fail(error)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // A successful download already consumed its context in
        // didFinishDownloadingTo, so reaching here with one means a failure.
        guard let context = removeContext(for: task.taskIdentifier) else { return }

        let rejectedRedirect = context.redirectDelegate.didRejectRedirect
        let failure: Error = rejectedRedirect ? CocoaError(.fileReadNoPermission) : error.map(FileDownloader.mapTransportError) ?? FindleError.downloadFailed(
            itemID: context.item.id,
            reason: "Download ended without producing a file"
        )
        context.record(!rejectedRedirect && (error as? URLError)?.code == .cancelled ? .cancelled : .failed,
                       error: rejectedRedirect ? failure : error ?? failure)
        logger.error("Download failed for \(context.item.id, privacy: .private): \(DiagnosticFailure(failure).summary, privacy: .public)")
        FileDownloader.resetToPlaceholderIfNeeded(item: context.item, database: context.database)
        context.bridge.fail(failure)
    }
}

final class FileDownloadCompletionBridge: @unchecked Sendable {
    private let lock = NSLock()
    private let progress: Progress
    private var completionHandler: ((URL?, NSFileProviderItem?, Error?) -> Void)?

    init(
        progress: Progress,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) {
        self.progress = progress
        self.completionHandler = completionHandler
    }

    func succeed(url: URL, item: NSFileProviderItem) {
        guard !progress.isCancelled else { fail(CocoaError(.userCancelled)); return }
        finish(progressState: .succeeded) { handler in
            handler(url, item, nil)
        }
    }

    func fail(_ error: Error) {
        // A failed materialization must leave a terminal Progress state. An
        // incomplete progress object makes Finder keep showing the item as
        // downloading even though its completion handler already failed.
        let nsError = error as NSError
        let reported: Error = [NSCocoaErrorDomain, NSFileProviderErrorDomain].contains(nsError.domain)
            ? error
            : NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid, userInfo: [NSUnderlyingErrorKey: error])
        finish(progressState: .failed) { handler in
            handler(nil, nil, reported)
        }
    }

    private enum TerminalProgressState {
        case succeeded
        case failed
    }

    private func finish(
        progressState: TerminalProgressState,
        calling callback: (((URL?, NSFileProviderItem?, Error?) -> Void) -> Void)
    ) {
        lock.lock()
        guard let handler = completionHandler else {
            lock.unlock()
            return
        }
        completionHandler = nil
        lock.unlock()
        switch progressState {
        case .succeeded:
            progress.completedUnitCount = progress.totalUnitCount
        case .failed:
            progress.cancel()
        }
        callback(handler)
    }
}
