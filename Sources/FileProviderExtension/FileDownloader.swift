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

        let task = URLSession.shared.downloadTask(with: authenticatedRequest) { downloadedURL, response, error in
            if let error {
                resetToPlaceholder(itemID: item.id, database: database)
                completionBridge.fail(error)
                return
            }

            guard let downloadedURL,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                resetToPlaceholder(itemID: item.id, database: database)
                completionBridge.fail(FindleError.downloadFailed(itemID: item.id, reason: "Download failed"))
                return
            }

            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.moveItem(at: downloadedURL, to: destinationURL)
                try database.updateItemSyncState(
                    id: item.id,
                    state: .materialized,
                    localPath: destinationURL.path
                )

                var updatedItem = item
                updatedItem.syncState = .materialized
                updatedItem.localPath = destinationURL.path
                completionBridge.succeed(
                    url: destinationURL,
                    item: FileProviderItem(localItem: updatedItem)
                )
            } catch {
                resetToPlaceholder(itemID: item.id, database: database)
                completionBridge.fail(error)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
        }
        task.resume()
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
