// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain

/// Activity completion: what the user has done in a course, and ticking off
/// activities set to manual completion.
extension MoodleClient {
    /// The tracked activities of a course. Activities without completion
    /// tracking are left out.
    public func fetchActivityCompletion(site: MoodleSite, token: AuthToken, courseID: Int, userID: Int) async throws -> [ActivityCompletion] {
        let response: CompletionStatusResponse = try await callWebService(
            site: site, token: token, function: "core_completion_get_activities_completion_status",
            params: ["courseid": String(courseID), "userid": String(userID)])
        return response.statuses.compactMap { status in
            // tracking: 0 none, 1 manual, 2 automatic. state: 1 complete, 2 complete and passed.
            guard (status.tracking ?? 0) != 0 else { return nil }
            return ActivityCompletion(moduleID: status.cmid, courseID: courseID, isManual: status.tracking == 1,
                                      isComplete: status.state == 1 || status.state == 2)
        }
    }

    /// Ticks an activity off, or back on. Only activities set to manual completion accept it.
    public func setActivityCompletion(site: MoodleSite, token: AuthToken, moduleID: Int, completed: Bool) async throws {
        let response: CompletionUpdateResponse = try await callWebService(
            site: site, token: token, function: "core_completion_update_activity_completion_status_manually",
            params: ["cmid": String(moduleID), "completed": completed ? "1" : "0"])
        guard response.status else {
            throw FindleError.requestFailed(statusCode: 200, detail: response.warnings?.first?.message ?? "Moodle didn't change the completion.")
        }
    }
}

struct CompletionStatusResponse: Decodable {
    let statuses: [Status]
    struct Status: Decodable {
        let cmid: Int
        let state: Int?
        let tracking: Int?
    }
}

struct CompletionUpdateResponse: Decodable {
    let status: Bool
    let warnings: [SubmissionWarning]?
}
