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
    private static func resetToPlaceholder(itemID: String, database: Database) {
        do {
            try database.updateItemSyncState(id: itemID, state: .placeholder)
        } catch {
            logger.error("Failed to reset \(itemID, privacy: .public) to placeholder after download failure: \(error.localizedDescription, privacy: .public)")
        }
    }
    static func startDownload(
        item: LocalItem,
        database: Database,
        progress: Progress,
        temporaryDirectory: URL? = nil,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) throws {
        let completionBridge = FileDownloadCompletionBridge(
            progress: progress,
            completionHandler: completionHandler
        )

        guard let remoteURL = item.remoteURL else {
            throw FindleError.downloadFailed(itemID: item.id, reason: "No remote URL available")
        }

        let tokenAccountID = try database.fetchAccounts().first(where: { $0.siteID == item.siteID })?.id ?? item.siteID
        guard let tokenString = try KeychainManager.shared.retrieveToken(forAccount: tokenAccountID) else {
            throw FindleError.authenticationRequired
        }

        // Send the token in the POST body instead of the URL query so it
        // doesn't leak into URLSession metrics, the Referer header on CDN
        // redirects, or crash reports that include the in-flight URL.
        var authenticatedRequest = URLRequest(url: remoteURL)
        authenticatedRequest.httpMethod = "POST"
        authenticatedRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        authenticatedRequest.httpBody = formEncodeToken(tokenString)

        let destinationURL = makeTemporaryDestinationURL(for: item, in: temporaryDirectory)
        try database.updateItemSyncState(id: item.id, state: .downloading)

        DownloadCoordinator.shared.start(
            request: authenticatedRequest,
            item: item,
            database: database,
            destination: destinationURL,
            progress: progress,
            bridge: completionBridge
        )
    }

    fileprivate static func resetToPlaceholderIfNeeded(itemID: String, database: Database) {
        resetToPlaceholder(itemID: itemID, database: database)
    }

    /// Form-encode just the token value for the download body. Using a
    /// restrictive allowed set avoids any chance that a token containing
    /// `+`, `&`, or `=` confuses Moodle's POST parser on the receiving side.
    private static func formEncodeToken(_ token: String) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = token.addingPercentEncoding(withAllowedCharacters: allowed) ?? token
        return "token=\(encoded)".data(using: .utf8)
    }

    private static func makeTemporaryDestinationURL(for item: LocalItem, in directory: URL?) -> URL {
        let pathExtension = (item.filename as NSString).pathExtension
        let baseName = item.id.replacingOccurrences(of: "/", with: "_")
        let tempDir = directory ?? FileManager.default.temporaryDirectory
        let fileName = pathExtension.isEmpty ? baseName : "\(baseName).\(pathExtension)"
        return tempDir.appendingPathComponent(fileName)
    }
}

/// Runs File Provider materializations on one shared delegate-backed session.
///
/// A delegate is what makes byte-level progress observable: the completion-handler
/// form of `downloadTask` reports nothing until it finishes, so Finder showed an
/// indeterminate spinner for the whole transfer — a 75 MB lecture PDF looked
/// identical to a hung download. Sharing a single session (rather than creating
/// one per file) preserves connection reuse to the Moodle host.
private final class DownloadCoordinator: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = DownloadCoordinator()

    private struct Context {
        let item: LocalItem
        let database: Database
        let destination: URL
        let progress: Progress
        let bridge: FileDownloadCompletionBridge
        /// Moodle reports each file's size in the course contents, so we can
        /// still show a real bar when a response omits `Content-Length`.
        let expectedSize: Int64
    }

    private let logger = Logger(subsystem: "es.amodrono.findle.file-provider", category: "Download")
    private let lock = NSLock()
    private var contexts: [Int: Context] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func start(
        request: URLRequest,
        item: LocalItem,
        database: Database,
        destination: URL,
        progress: Progress,
        bridge: FileDownloadCompletionBridge
    ) {
        let task = session.downloadTask(with: request)
        let context = Context(
            item: item,
            database: database,
            destination: destination,
            progress: progress,
            bridge: bridge,
            expectedSize: item.fileSize
        )

        // Register before `resume()` so no delegate callback can arrive first.
        lock.lock()
        contexts[task.taskIdentifier] = context
        lock.unlock()

        progress.cancellationHandler = { task.cancel() }
        task.resume()
    }

    private func context(for taskIdentifier: Int) -> Context? {
        lock.lock()
        defer { lock.unlock() }
        return contexts[taskIdentifier]
    }

    @discardableResult
    private func removeContext(for taskIdentifier: Int) -> Context? {
        lock.lock()
        defer { lock.unlock() }
        return contexts.removeValue(forKey: taskIdentifier)
    }

    // MARK: - URLSessionDownloadDelegate

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

        guard let httpResponse = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            removeContext(for: downloadTask.taskIdentifier)
            FileDownloader.resetToPlaceholderIfNeeded(itemID: context.item.id, database: context.database)
            context.bridge.fail(
                FindleError.downloadFailed(itemID: context.item.id, reason: "Download failed")
            )
            return
        }

        // The temporary file is deleted as soon as this method returns, so the
        // move has to happen here rather than in didCompleteWithError.
        do {
            if FileManager.default.fileExists(atPath: context.destination.path) {
                try FileManager.default.removeItem(at: context.destination)
            }
            try FileManager.default.moveItem(at: location, to: context.destination)
            try context.database.updateItemSyncState(
                id: context.item.id,
                state: .materialized,
                localPath: context.destination.path
            )

            var updatedItem = context.item
            updatedItem.syncState = .materialized
            updatedItem.localPath = context.destination.path

            removeContext(for: downloadTask.taskIdentifier)
            context.bridge.succeed(
                url: context.destination,
                item: FileProviderItem(localItem: updatedItem)
            )
        } catch {
            removeContext(for: downloadTask.taskIdentifier)
            FileDownloader.resetToPlaceholderIfNeeded(itemID: context.item.id, database: context.database)
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

        let failure = error ?? FindleError.downloadFailed(
            itemID: context.item.id,
            reason: "Download ended without producing a file"
        )
        logger.error("Download failed for \(context.item.id, privacy: .public): \(failure.localizedDescription, privacy: .public)")
        FileDownloader.resetToPlaceholderIfNeeded(itemID: context.item.id, database: context.database)
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
        finish(progressState: .succeeded) { handler in
            handler(url, item, nil)
        }
    }

    func fail(_ error: Error) {
        // A failed materialization must leave a terminal Progress state. An
        // incomplete progress object makes Finder keep showing the item as
        // downloading even though its completion handler already failed.
        finish(progressState: .failed) { handler in
            handler(nil, nil, error)
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
        switch progressState {
        case .succeeded:
            progress.completedUnitCount = progress.totalUnitCount
        case .failed:
            progress.cancel()
        }
        lock.unlock()
        callback(handler)
    }
}
