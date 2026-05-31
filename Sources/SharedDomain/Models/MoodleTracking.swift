// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// A Moodle assignment with its due dates and the user's submission state.
/// Read-only coursework tracking — Findle never submits.
public struct MoodleAssignment: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let courseID: Int
    public let name: String
    public let dueDate: Date?
    public let cutoffDate: Date?
    /// Submission lifecycle, filled from `mod_assign_get_submission_status`.
    public var submitted: Bool
    public var graded: Bool
    public var grade: String?

    public init(
        id: Int,
        courseID: Int,
        name: String,
        dueDate: Date? = nil,
        cutoffDate: Date? = nil,
        submitted: Bool = false,
        graded: Bool = false,
        grade: String? = nil
    ) {
        self.id = id
        self.courseID = courseID
        self.name = name
        self.dueDate = dueDate
        self.cutoffDate = cutoffDate
        self.submitted = submitted
        self.graded = graded
        self.grade = grade
    }
}

/// A single grade-book item (an assignment grade, exam grade, course total, …).
public struct MoodleGradeItem: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let courseID: Int
    public let itemName: String
    public let grade: String?
    public let percentage: String?
    public let feedback: String?

    public init(
        id: Int,
        courseID: Int,
        itemName: String,
        grade: String? = nil,
        percentage: String? = nil,
        feedback: String? = nil
    ) {
        self.id = id
        self.courseID = courseID
        self.itemName = itemName
        self.grade = grade
        self.percentage = percentage
        self.feedback = feedback
    }
}

/// A Moodle quiz with its open/close window.
public struct MoodleQuiz: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let courseID: Int
    public let name: String
    public let openDate: Date?
    public let closeDate: Date?
    public let timeLimit: Int?

    public init(
        id: Int,
        courseID: Int,
        name: String,
        openDate: Date? = nil,
        closeDate: Date? = nil,
        timeLimit: Int? = nil
    ) {
        self.id = id
        self.courseID = courseID
        self.name = name
        self.openDate = openDate
        self.closeDate = closeDate
        self.timeLimit = timeLimit
    }
}

/// One of the user's attempts at a quiz.
public struct MoodleQuizAttempt: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let quizID: Int
    public let attemptNumber: Int
    public let state: String
    public let sumGrades: Double?
    public let startTime: Date?
    public let finishTime: Date?

    public init(
        id: Int,
        quizID: Int,
        attemptNumber: Int,
        state: String,
        sumGrades: Double? = nil,
        startTime: Date? = nil,
        finishTime: Date? = nil
    ) {
        self.id = id
        self.quizID = quizID
        self.attemptNumber = attemptNumber
        self.state = state
        self.sumGrades = sumGrades
        self.startTime = startTime
        self.finishTime = finishTime
    }
}
