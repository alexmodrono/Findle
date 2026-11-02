// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import Foundation
import OSLog
import SharedDomain
import FindleNetworking
import FindlePersistence
import FindleSyncEngine

/// The Submit folder of an open assignment is its draft submission (FX-06).
/// The files dropped there are the user's personal files, kept like any
/// other; whenever they change, the whole folder is uploaded to a new draft
/// area and saved as the draft, and an empty folder clears it. Nothing is
/// submitted for grading here; that needs the user's confirmation in
/// Assignment Details.
actor SubmissionDrafts {
    static let shared = SubmissionDrafts()
    private let logger = Logger(subsystem: "es.amodrono.findle.file-provider", category: "Submission")
    private var running: Set<String> = []
    private var dirty: Set<String> = []

    static func isSubmitFolder(_ id: String?) -> Bool { SubmissionUploader.isSubmitFolder(id) }

    /// Brings the draft in line with the folder. Changes while an upload runs
    /// are picked up by one more pass, so the last state always wins.
    func folderChanged(_ folderID: String, database: Database) {
        guard !running.contains(folderID) else {
            dirty.insert(folderID)
            return
        }
        running.insert(folderID)
        Task {
            repeat {
                dirty.remove(folderID)
                do {
                    try await upload(folderID, database: database)
                } catch {
                    DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                        process: .fileProvider, operation: .download, outcome: .failed, failure: DiagnosticFailure(error)))
                    logger.error("Could not save the draft submission: \(DiagnosticFailure(error).summary, privacy: .public)")
                }
            } while dirty.contains(folderID)
            running.remove(folderID)
        }
    }

    private func upload(_ folderID: String, database: Database) async throws {
        guard let folder = try database.fetchItem(id: folderID) else { return }
        let accountID = try database.fetchAccounts().first { $0.siteID == folder.siteID }?.id ?? folder.siteID
        guard let token = try KeychainManager.shared.retrieveToken(forAccount: accountID) else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let count = try await SubmissionUploader.saveDraft(folderID: folderID, database: database, token: AuthToken(token: token))
        logger.info("Saved the draft submission with \(count, privacy: .public) files")
    }
}
