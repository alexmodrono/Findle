// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// Course data the File Provider extension serves to Findle's other extensions
/// (Finder sheets, the Share menu, the toolbar button), which can't open the
/// database: it lives in the File Provider's own sandbox.
///
/// Clients reach the service through an item in the Findle location with
/// `FileManager.getFileProviderServicesForItem(at:)`, looking for `serviceName`.
/// The service is read-only, and only processes signed by the same team can
/// connect. Replies carry JSON so the payloads can grow without new XPC types.
public enum CourseDataService {
    public static let serviceName = "com.amodrono.findle.course-data"

    public struct Course: Codable, Sendable, Equatable {
        public let id: Int
        public let shortName: String
        public let fullName: String
        /// The course's folder name in Finder.
        public let folderName: String

        public init(id: Int, shortName: String, fullName: String, folderName: String) {
            self.id = id
            self.shortName = shortName
            self.fullName = fullName
            self.folderName = folderName
        }
    }

    public struct Coursework: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case assignment, quiz
        }

        public let kind: Kind
        public let id: Int
        public let courseID: Int
        public let name: String
        /// When an assignment is due or a quiz closes.
        public let due: Date
        /// Whether the assignment was submitted; nil for quizzes.
        public let submitted: Bool?

        public init(kind: Kind, id: Int, courseID: Int, name: String, due: Date, submitted: Bool?) {
            self.kind = kind
            self.id = id
            self.courseID = courseID
            self.name = name
            self.due = due
            self.submitted = submitted
        }
    }

    /// Subscribed courses, by name.
    public static func courses(from courses: [MoodleCourse]) -> [Course] {
        courses.filter(\.isSyncEnabled)
            .map { Course(id: $0.id, shortName: $0.shortName, fullName: $0.fullName, folderName: $0.effectiveFolderName) }
            .sorted { $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending }
    }

    /// Assignments not yet due and quizzes not yet closed in subscribed courses,
    /// soonest first.
    public static func upcomingCoursework(
        courses: [MoodleCourse], assignments: [MoodleAssignment], quizzes: [MoodleQuiz], now: Date = Date()
    ) -> [Coursework] {
        let subscribed = Set(courses.filter(\.isSyncEnabled).map(\.id))
        let due = assignments.compactMap { assignment -> Coursework? in
            guard subscribed.contains(assignment.courseID), let date = assignment.dueDate, date >= now else { return nil }
            return Coursework(kind: .assignment, id: assignment.id, courseID: assignment.courseID,
                              name: assignment.name, due: date, submitted: assignment.submitted)
        }
        let closing = quizzes.compactMap { quiz -> Coursework? in
            guard subscribed.contains(quiz.courseID), let date = quiz.closeDate, date >= now else { return nil }
            return Coursework(kind: .quiz, id: quiz.id, courseID: quiz.courseID, name: quiz.name, due: date, submitted: nil)
        }
        return (due + closing).sorted { ($0.due, $0.name) < ($1.due, $1.name) }
    }

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

/// The XPC interface of `CourseDataService`. Each reply is JSON for an array of
/// `CourseDataService.Course` or `CourseDataService.Coursework`, or an error.
@objc public protocol CourseDataServiceProtocol {
    func fetchCourses(reply: @escaping @Sendable (Data?, Error?) -> Void)
    func fetchUpcomingCoursework(reply: @escaping @Sendable (Data?, Error?) -> Void)
}
