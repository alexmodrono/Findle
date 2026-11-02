// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// What Finder's Course Info and Assignment Details sheets show (FX-03).
extension CourseDataService {
    public struct CourseInfo: Codable, Sendable, Equatable {
        public let id: Int
        public let fullName: String
        public let shortName: String
        public let teachers: [String]
        public let sections: [String]
        public let lastSync: Date?
        /// What the course takes on this Mac: downloaded Moodle files and personal files.
        public let storageBytes: Int64
        public let keptOffline: Bool
    }

    public struct AssignmentDetails: Codable, Sendable, Equatable {
        public let name: String
        public let courseName: String
        public let brief: String?
        public let due: Date?
        public let cutoff: Date?
        public let submitted: Bool
        public let graded: Bool
        public let grade: String?

        public var status: String {
            if graded { return grade.map { "Graded: \($0)" } ?? "Graded" }
            return submitted ? "Submitted" : "Not submitted"
        }
    }

    /// `keptPreviousBytes` are the previous versions Findle keeps for the course.
    public static func courseInfo(course: MoodleCourse, teachers: [String], outline: CourseOutlineSnapshot?,
                                  lastSync: Date?, items: [LocalItem], keptPreviousBytes: Int64 = 0) -> CourseInfo {
        let sections = (outline?.sections ?? []).filter(\.visible).sorted { $0.sectionNumber < $1.sectionNumber }.map(\.name)
        let onMac = items.filter { !$0.isDirectory && ($0.isLocal || $0.syncState == .materialized) }
        let courseFolder = items.first { $0.id == "course-\(course.siteID)-\(course.id)" }
        return CourseInfo(id: course.id, fullName: course.fullName, shortName: course.shortName, teachers: teachers,
                          sections: sections, lastSync: lastSync,
                          storageBytes: onMac.reduce(0) { $0 + max($1.fileSize, 0) } + keptPreviousBytes,
                          keptOffline: courseFolder?.isPinned ?? false)
    }

    /// `folder` is the assignment's folder (`assign-<site>-<course>-<module>`).
    public static func assignmentDetails(folder: LocalItem, assignment: MoodleAssignment?, courseName: String,
                                         brief: String?) -> AssignmentDetails {
        AssignmentDetails(name: assignment?.name ?? folder.filename, courseName: courseName, brief: brief,
                          due: assignment?.dueDate, cutoff: assignment?.cutoffDate,
                          submitted: assignment?.submitted ?? false, graded: assignment?.graded ?? false,
                          grade: assignment?.grade)
    }
}

/// The calls Finder's sheets make. The kept state is the one write: it is
/// what Finder's own Keep Course Offline action changes.
@objc public protocol CourseDataSheetsProtocol: CourseDataServiceProtocol {
    func fetchCourseInfo(courseID: Int, reply: @escaping @Sendable (Data?, Error?) -> Void)
    func fetchAssignmentDetails(itemID: String, reply: @escaping @Sendable (Data?, Error?) -> Void)
    func setCourseKeptOffline(courseID: Int, kept: Bool, reply: @escaping @Sendable (Error?) -> Void)
}
