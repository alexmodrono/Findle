// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import OSLog

/// Token endpoint response.
struct TokenResponse: Decodable {
    let token: String?
    let privatetoken: String?
    let error: String?
    let errorcode: String?
    let message: String?
}

/// Decodes an array element by element, dropping elements that fail to decode
/// instead of failing the whole array. Consumers must inspect discardedCount
/// before treating the decoded elements as a complete remote snapshot.
struct LossyArray<Element: Decodable>: Decodable {
    private static var logger: Logger {
        Logger(subsystem: "es.amodrono.findle.networking", category: "MoodleResponses")
    }

    let elements: [Element]
    let discardedCount: Int

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var discardedCount = 0
        while !container.isAtEnd {
            // FailableDecodable always succeeds, so the container advances past bad entries.
            let wrapper = try container.decode(FailableDecodable<Element>.self)
            if let element = wrapper.base {
                elements.append(element)
            } else {
                discardedCount += 1
                Self.logger.error("Skipped a \(String(describing: Element.self), privacy: .public) entry that failed to decode")
            }
        }
        self.elements = elements
        self.discardedCount = discardedCount
    }

    private struct FailableDecodable<Base: Decodable>: Decodable {
        let base: Base?

        init(from decoder: Decoder) throws {
            base = try? Base(from: decoder)
        }
    }
}

/// Site info response from core_webservice_get_site_info.
struct SiteInfoResponse: Decodable {
    let sitename: String
    let username: String
    let fullname: String
    let userid: Int
    let siteurl: String
    let userpictureurl: String?
    let lang: String?
    let release: String?
    let version: String?
}

/// Course response from core_enrol_get_users_courses.
struct CourseResponse: Decodable {
    let id: Int
    let shortname: String
    let fullname: String
    let summary: String?
    let category: Int?
    let startdate: Int?
    let enddate: Int?
    let lastaccess: Int?
    let visible: Int?
    /// Course card/banner images. The first image-type entry is used as the
    /// gallery cover. Absent on many older sites, so it's optional.
    let overviewfiles: [OverviewFileResponse]?
}

/// A single course overview file (image or document) from `overviewfiles`.
struct OverviewFileResponse: Decodable {
    let fileurl: String?
    let mimetype: String?
}

/// Section response from core_course_get_contents.
struct SectionResponse: Decodable {
    let id: Int
    /// Moodle can return a null name for unnamed sections.
    let name: String?
    let summary: String?
    let section: Int
    let visible: Int?
    let modules: LossyArray<ModuleResponse>?
}

/// Module response within a section.
struct ModuleResponse: Decodable {
    let id: Int
    let name: String?
    /// Module type (e.g. "resource", "url"). A missing type makes the course snapshot incomplete.
    let modname: String?
    let modicon: String?
    let visible: Int?
    let contents: LossyArray<ContentResponse>?
}

/// File content response within a module.
struct ContentResponse: Decodable {
    /// Content kind ("file", "url", "content"). Defaults to "file" when Moodle omits it.
    let type: String?
    /// Display name. A missing name makes the course snapshot incomplete.
    let filename: String?
    let filepath: String?
    let filesize: Int64?
    let fileurl: String?
    let timecreated: Int?
    let timemodified: Int?
    let mimetype: String?
    let author: String?
    let sortorder: Int?
}

// MARK: - Coursework Tracking Responses

/// `mod_assign_get_assignments`
struct AssignmentsResponse: Decodable {
    let courses: [AssignmentCourse]
    struct AssignmentCourse: Decodable {
        let id: Int
        let assignments: [AssignmentItem]
    }
    struct AssignmentItem: Decodable {
        let id: Int
        let course: Int
        let name: String
        let duedate: Int?
        let cutoffdate: Int?
    }
}

/// `mod_assign_get_submission_status`
struct SubmissionStatusResponse: Decodable {
    let lastattempt: LastAttempt?
    let feedback: Feedback?
    struct LastAttempt: Decodable {
        let submission: Submission?
        let gradingstatus: String?
        struct Submission: Decodable { let status: String? }
    }
    struct Feedback: Decodable {
        let grade: Grade?
        struct Grade: Decodable { let grade: String? }
    }
}

/// `gradereport_user_get_grade_items`
struct GradeItemsResponse: Decodable {
    let usergrades: [UserGrade]
    struct UserGrade: Decodable {
        let courseid: Int
        let gradeitems: [GradeItemResponse]
    }
    struct GradeItemResponse: Decodable {
        let id: Int
        let itemname: String?
        let gradeformatted: String?
        let percentageformatted: String?
        let feedback: String?
    }
}

/// `mod_quiz_get_quizzes_by_courses`
struct QuizzesResponse: Decodable {
    let quizzes: [QuizItem]
    struct QuizItem: Decodable {
        let id: Int
        let course: Int
        let name: String
        let timeopen: Int?
        let timeclose: Int?
        let timelimit: Int?
    }
}

/// `mod_quiz_get_user_attempts`
struct QuizAttemptsResponse: Decodable {
    let attempts: [AttemptItem]
    struct AttemptItem: Decodable {
        let id: Int
        let quiz: Int
        let attempt: Int
        let state: String
        let sumgrades: Double?
        let timestart: Int?
        let timefinish: Int?
    }
}
