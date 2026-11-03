// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain
import FindleNetworking
import FindlePersistence

/// An assignment's Submit folder is its draft submission (FX-06, FX-07): the
/// whole folder is uploaded to a new draft area and saved, and an empty
/// folder clears the draft. Used by the File Provider extension when files
/// change in Finder, and by the app for files shared to Findle.
public enum SubmissionUploader {
    public static func submitFolderID(siteID: String, courseID: Int, moduleID: Int) -> String {
        "submit-\(siteID)-\(courseID)-\(moduleID)"
    }

    public static func isSubmitFolder(_ id: String?) -> Bool { id?.hasPrefix("submit-") == true }

    /// Saves the folder's files as the draft. Returns how many were uploaded.
    @discardableResult
    public static func saveDraft(folderID: String, database: Database, client: MoodleClient = MoodleClient(),
                                 token: AuthToken) async throws -> Int {
        guard let folder = try database.fetchItem(id: folderID),
              let site = try database.fetchSite(id: folder.siteID),
              let assignment = try database.fetchAssignments(siteID: folder.siteID)
                .first(where: { $0.courseID == folder.courseID && $0.moduleID == folder.remoteID }),
              assignment.acceptsFilesFromFinder else { return 0 }
        let files = try database.fetchItems(parentID: folderID, siteID: folder.siteID)
            .filter { $0.isLocal && $0.id.hasPrefix("local-") && !$0.isDirectory && $0.localPath != nil }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        guard !files.isEmpty else {
            try await client.clearSubmissionFiles(site: site, token: token, assignmentID: assignment.id)
            return 0
        }
        var draftItemID: Int?
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: file.localPath!))
            draftItemID = try await client.uploadDraftFile(site: site, token: token, data: data, filename: file.filename,
                                                           draftItemID: draftItemID).draftItemID
        }
        if let draftItemID {
            try await client.saveSubmission(site: site, token: token, assignmentID: assignment.id, draftItemID: draftItemID)
        }
        return files.count
    }
}
