// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain
import FoodleNetworking
import FoodlePersistence

/// Handles file downloads for the File Provider extension.
/// Structured as a static utility to avoid Sendable issues with NSObject-based extension classes.
enum FileDownloader {
    static func download(item: LocalItem, database: Database) async throws -> URL {
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

        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent(item.filename)

        let (downloadedURL, response) = try await URLSession.shared.download(for: URLRequest(url: authenticatedURL))

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw FoodleError.downloadFailed(itemID: item.id, reason: "Download failed")
        }

        if FileManager.default.fileExists(atPath: tempFile.path) {
            try FileManager.default.removeItem(at: tempFile)
        }
        try FileManager.default.moveItem(at: downloadedURL, to: tempFile)

        return tempFile
    }
}
