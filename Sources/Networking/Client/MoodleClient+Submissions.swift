// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain

/// Whether, and how, the user can hand work in for an assignment. The
/// interface hides submission wherever this says it would fail.
public struct SubmissionSupport: Sendable, Equatable {
    /// The site lets the app upload files and call the submission functions.
    public let siteAllowsUploads: Bool
    /// The assignment takes file submissions.
    public let acceptsFiles: Bool
    public let acceptsOnlineText: Bool
    /// Moodle's limits, when the assignment sets them.
    public let maxFiles: Int?
    public let maxBytes: Int64?
    /// Accepted extensions or type groups, empty when anything goes.
    public let acceptedTypes: [String]
    /// The user can change their submission now (open, not locked, not graded final).
    public let canEdit: Bool
    /// The draft can be submitted for grading now.
    public let canSubmit: Bool
    /// Submissions stay drafts until submitted for grading.
    public let usesDrafts: Bool
    /// Submitting needs the user to accept the site's submission statement.
    public let requiresStatement: Bool

    public init(siteAllowsUploads: Bool, acceptsFiles: Bool, acceptsOnlineText: Bool, maxFiles: Int?, maxBytes: Int64?,
                acceptedTypes: [String], canEdit: Bool, canSubmit: Bool, usesDrafts: Bool, requiresStatement: Bool) {
        self.siteAllowsUploads = siteAllowsUploads
        self.acceptsFiles = acceptsFiles
        self.acceptsOnlineText = acceptsOnlineText
        self.maxFiles = maxFiles
        self.maxBytes = maxBytes
        self.acceptedTypes = acceptedTypes
        self.canEdit = canEdit
        self.canSubmit = canSubmit
        self.usesDrafts = usesDrafts
        self.requiresStatement = requiresStatement
    }

    /// Files can be uploaded as this assignment's submission now.
    public var allowsFileSubmission: Bool { siteAllowsUploads && acceptsFiles && canEdit }

    static let none = SubmissionSupport(siteAllowsUploads: false, acceptsFiles: false, acceptsOnlineText: false,
                                        maxFiles: nil, maxBytes: nil, acceptedTypes: [], canEdit: false,
                                        canSubmit: false, usesDrafts: false, requiresStatement: false)
}

/// A file uploaded to the user's draft area, ready to be saved as a submission.
public struct DraftFile: Sendable, Equatable {
    public let draftItemID: Int
    public let filename: String
}

/// Moodle's submission calls: upload to the draft area, save the draft as the
/// submission, and submit it for grading. Findle never submits on its own;
/// the interface asks the user first.
extension MoodleClient {
    static let submissionFunctions = ["mod_assign_save_submission", "mod_assign_submit_for_grading",
                                      "mod_assign_get_submission_status"]

    /// What the site and the assignment allow. A site that disables uploads or
    /// keeps the submission functions from the app allows nothing.
    public func submissionSupport(site: MoodleSite, token: AuthToken, courseID: Int, assignmentID: Int) async throws -> SubmissionSupport {
        let info: SubmissionSiteInfoResponse = try await callWebService(site: site, token: token, function: "core_webservice_get_site_info")
        let available = Set(info.functions?.map(\.name) ?? [])
        let siteAllowsUploads = info.uploadfiles == true && Self.submissionFunctions.allSatisfy(available.contains)
        guard siteAllowsUploads else { return .none }

        let assignments: SubmissionAssignmentsResponse = try await callWebService(
            site: site, token: token, function: "mod_assign_get_assignments",
            params: ["courseids[0]": String(courseID)])
        guard let assignment = assignments.courses.flatMap(\.assignments).first(where: { $0.id == assignmentID }) else {
            return .none
        }
        func config(_ plugin: String, _ name: String) -> String? {
            assignment.configs?.first { $0.subtype == "assignsubmission" && $0.plugin == plugin && $0.name == name }?.value
        }
        let status: SubmissionEditStatusResponse = try await callWebService(
            site: site, token: token, function: "mod_assign_get_submission_status",
            params: ["assignid": String(assignmentID)])
        let types = (config("file", "filetypeslist") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init)
        return SubmissionSupport(
            siteAllowsUploads: true,
            acceptsFiles: config("file", "enabled") == "1",
            acceptsOnlineText: config("onlinetext", "enabled") == "1",
            maxFiles: config("file", "maxfilesubmissions").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil },
            maxBytes: config("file", "maxsubmissionsizebytes").flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil },
            acceptedTypes: types,
            canEdit: status.lastattempt?.canedit ?? false,
            canSubmit: status.lastattempt?.cansubmit ?? false,
            usesDrafts: assignment.submissiondrafts == 1,
            requiresStatement: assignment.requiresubmissionstatement == 1)
    }

    /// Uploads a file to the user's draft area. Pass the item id of an earlier
    /// upload to add files to the same draft; nil starts a new one.
    public func uploadDraftFile(site: MoodleSite, token: AuthToken, data: Data, filename: String,
                                draftItemID: Int? = nil) async throws -> DraftFile {
        let url = site.uploadURL
        let origin = try credentialOrigin(site: site, destination: url)
        let boundary = "Findle-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("token", token.token)
        field("filearea", "draft")
        field("itemid", String(draftItemID ?? 0))
        let safeName = filename.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file_1\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (responseData, response) = try await performRequest(request, policy: .upload, credentialOrigin: origin)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw FindleError.requestFailed(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                                            detail: "The upload was rejected.")
        }
        let json = try Self.parseJSON(responseData, context: "upload")
        if let object = json as? [String: Any] {
            if object["errorcode"] as? String == "invalidtoken" { throw FindleError.tokenExpired }
            throw FindleError.requestFailed(statusCode: http.statusCode,
                                            detail: object["error"] as? String ?? object["message"] as? String ?? "The upload was rejected.")
        }
        guard let first = (json as? [[String: Any]])?.first, let itemID = first["itemid"] as? Int else {
            throw FindleError.invalidResponse(detail: "upload: no draft item in the response")
        }
        return DraftFile(draftItemID: itemID, filename: first["filename"] as? String ?? filename)
    }

    /// Saves the files in a draft area as the user's submission, replacing what
    /// was there. On assignments that use drafts it stays a draft.
    public func saveSubmission(site: MoodleSite, token: AuthToken, assignmentID: Int, draftItemID: Int) async throws {
        let warnings: [SubmissionWarning] = try await callWebService(
            site: site, token: token, function: "mod_assign_save_submission",
            params: ["assignmentid": String(assignmentID), "plugindata[files_filemanager]": String(draftItemID)])
        try Self.check(warnings)
    }

    /// Removes the submitted files by saving an empty draft area in their place.
    public func clearSubmissionFiles(site: MoodleSite, token: AuthToken, assignmentID: Int) async throws {
        let empty: UnusedDraftResponse = try await callWebService(site: site, token: token,
                                                                  function: "core_files_get_unused_draft_itemid")
        try await saveSubmission(site: site, token: token, assignmentID: assignmentID, draftItemID: empty.itemid)
    }

    /// Submits the draft for grading. Only ever called after the user confirmed.
    public func submitForGrading(site: MoodleSite, token: AuthToken, assignmentID: Int, acceptStatement: Bool) async throws {
        let warnings: [SubmissionWarning] = try await callWebService(
            site: site, token: token, function: "mod_assign_submit_for_grading",
            params: ["assignmentid": String(assignmentID), "acceptsubmissionstatement": acceptStatement ? "1" : "0"])
        try Self.check(warnings)
    }

    /// Moodle reports refused submissions as warnings in a successful response.
    private static func check(_ warnings: [SubmissionWarning]) throws {
        guard let warning = warnings.first else { return }
        throw FindleError.requestFailed(statusCode: 200, detail: warning.message ?? warning.warningcode ?? "Moodle refused the submission.")
    }
}

struct SubmissionSiteInfoResponse: Decodable {
    let uploadfiles: Bool?
    let functions: [Function]?
    struct Function: Decodable { let name: String }
}

struct SubmissionAssignmentsResponse: Decodable {
    let courses: [Course]
    struct Course: Decodable { let assignments: [Assignment] }
    struct Assignment: Decodable {
        let id: Int
        let submissiondrafts: Int?
        let requiresubmissionstatement: Int?
        let configs: [Config]?
    }
    struct Config: Decodable {
        let plugin: String
        let subtype: String
        let name: String
        let value: String?
    }
}

struct SubmissionEditStatusResponse: Decodable {
    let lastattempt: LastAttempt?
    struct LastAttempt: Decodable {
        let canedit: Bool?
        let cansubmit: Bool?
    }
}

struct SubmissionWarning: Decodable {
    let item: String?
    let warningcode: String?
    let message: String?
}

struct UnusedDraftResponse: Decodable {
    let itemid: Int
}
