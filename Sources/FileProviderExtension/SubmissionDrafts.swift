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

    static func isSubmitFolder(_ id: String?) -> Bool { id?.hasPrefix("submit-") == true }

    /// The Submit folder of an assignment's folder.
    static func submitFolderID(siteID: String, courseID: Int, moduleID: Int) -> String {
        "submit-\(siteID)-\(courseID)-\(moduleID)"
    }

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
        guard let folder = try database.fetchItem(id: folderID),
              let site = try database.fetchSite(id: folder.siteID),
              let assignment = try database.fetchAssignments(siteID: folder.siteID)
                .first(where: { $0.courseID == folder.courseID && $0.moduleID == folder.remoteID }),
              assignment.acceptsFilesFromFinder else { return }
        let accountID = try database.fetchAccounts().first { $0.siteID == site.id }?.id ?? site.id
        guard let tokenValue = try KeychainManager.shared.retrieveToken(forAccount: accountID) else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let token = AuthToken(token: tokenValue)
        let client = MoodleClient()
        let files = try database.fetchItems(parentID: folderID, siteID: folder.siteID)
            .filter { isUserItem($0) && !$0.isDirectory && $0.localPath != nil }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        guard !files.isEmpty else {
            try await client.clearSubmissionFiles(site: site, token: token, assignmentID: assignment.id)
            logger.info("Cleared the draft submission")
            return
        }
        var draftItemID: Int?
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.localPath!))
            draftItemID = try await client.uploadDraftFile(site: site, token: token, data: data, filename: file.filename,
                                                           draftItemID: draftItemID).draftItemID
        }
        if let draftItemID {
            try await client.saveSubmission(site: site, token: token, assignmentID: assignment.id, draftItemID: draftItemID)
            logger.info("Saved a draft submission with \(files.count, privacy: .public) files")
        }
    }
}
