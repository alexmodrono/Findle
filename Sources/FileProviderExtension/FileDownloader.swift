// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import FileProvider
import SharedDomain
import FoodleNetworking
import FoodlePersistence

/// Handles file downloads for the File Provider extension.
/// Uses URLSession's callback API so File Provider completion handlers stay in the
/// framework's callback world instead of crossing Swift concurrency executors.
enum FileDownloader {
    static func startDownload(
        item: LocalItem,
        database: Database,
        progress: Progress,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) throws {
        let completionBridge = FileDownloadCompletionBridge(
            progress: progress,
            completionHandler: completionHandler
        )

        guard let remoteURL = item.remoteURL else {
            throw FoodleError.downloadFailed(itemID: item.id, reason: "No remote URL available")
        }

        let tokenAccountID = try database.fetchAccounts().first(where: { $0.siteID == item.siteID })?.id ?? item.siteID
        guard let tokenString = try KeychainManager.shared.retrieveToken(forAccount: tokenAccountID) else {
            throw FoodleError.authenticationRequired
        }

        guard var components = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false) else {
            throw FoodleError.downloadFailed(itemID: item.id, reason: "Could not construct download URL")
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "token", value: tokenString))
        components.queryItems = queryItems

        guard let authenticatedURL = components.url else {
            throw FoodleError.downloadFailed(itemID: item.id, reason: "Could not construct download URL")
        }

        let destinationURL = makeTemporaryDestinationURL(for: item)
        try database.updateItemSyncState(id: item.id, state: .downloading)

        let task = URLSession.shared.downloadTask(with: URLRequest(url: authenticatedURL)) { downloadedURL, response, error in
            if let error {
                try? database.updateItemSyncState(id: item.id, state: .placeholder)
                completionBridge.fail(error)
                return
            }

            guard let downloadedURL,
                  let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                try? database.updateItemSyncState(id: item.id, state: .placeholder)
                completionBridge.fail(FoodleError.downloadFailed(itemID: item.id, reason: "Download failed"))
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
                try? database.updateItemSyncState(id: item.id, state: .placeholder)
                completionBridge.fail(error)
            }
        }

        progress.cancellationHandler = {
            task.cancel()
        }
        task.resume()
    }

    private static func makeTemporaryDestinationURL(for item: LocalItem) -> URL {
        let pathExtension = (item.filename as NSString).pathExtension
        let baseName = item.id.replacingOccurrences(of: "/", with: "_")
        let tempDir = FileManager.default.temporaryDirectory
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
        progress.completedUnitCount = progress.totalUnitCount
        takeCompletionHandler()?(url, item, nil)
    }

    func fail(_ error: Error) {
        takeCompletionHandler()?(nil, nil, error)
    }

    private func takeCompletionHandler() -> ((URL?, NSFileProviderItem?, Error?) -> Void)? {
        lock.lock()
        defer { lock.unlock() }

        let handler = completionHandler
        completionHandler = nil
        return handler
    }
}
