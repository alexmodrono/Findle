// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import FoodlePersistence
import SharedDomain

/// Builds a throwaway database seeded with a small, known fixture, so the MCP
/// catalog/tracking tools can be exercised deterministically.
enum TestDB {
    static let siteID = "TESTSITE"

    static func make(seed: Bool = true) throws -> Database {
        let path = NSTemporaryDirectory() + "findle-mcp-test-\(UUID().uuidString).db"
        let db = try Database(path: path)
        guard seed else { return db }

        // The accounts table has a foreign key to sites, so seed the site first.
        try db.saveSite(MoodleSite(id: siteID, displayName: "Test", baseURL: URL(string: "https://moodle.test")!))
        try db.saveAccount(Account(id: "acc", siteID: siteID, userID: 7, state: .authenticated(userID: 7)))

        try db.saveCourses([
            MoodleCourse(id: 100, shortName: "CALC", fullName: "Cálculo", siteID: siteID),
            MoodleCourse(id: 200, shortName: "FIS", fullName: "Física", siteID: siteID, isSyncEnabled: false)
        ])

        // Course 100 tree: root → "Exámenes" folder → two files.
        let root = LocalItem(id: "course-\(siteID)-100", parentID: nil, siteID: siteID, courseID: 100, remoteID: 100, filename: "Cálculo", isDirectory: true, syncState: .materialized)
        let section = LocalItem(id: "sec1", parentID: root.id, siteID: siteID, courseID: 100, remoteID: 1, filename: "Exámenes", isDirectory: true, syncState: .materialized)
        let file1 = LocalItem(id: "f1", parentID: section.id, siteID: siteID, courseID: 100, remoteID: 2, filename: "Examen Final.pdf", fileSize: 1000, syncState: .materialized, remoteURL: URL(string: "https://moodle/file/2"))
        let file2 = LocalItem(id: "f2", parentID: section.id, siteID: siteID, courseID: 100, remoteID: 3, filename: "Tema 1 Derivadas.pdf", fileSize: 2000, syncState: .placeholder)
        try db.saveItems([root, section, file1, file2])
        try db.saveSyncCursor(SyncCursor(courseID: 100, siteID: siteID, lastSyncDate: Date(timeIntervalSince1970: 1_700_000_000), itemCount: 2))

        try db.saveAssignments([
            MoodleAssignment(id: 901, courseID: 100, name: "Entrega 1", dueDate: Date().addingTimeInterval(3 * 86400)),
            MoodleAssignment(id: 902, courseID: 100, name: "Entrega 2 (past)", dueDate: Date().addingTimeInterval(-10 * 86400), submitted: true, graded: true, grade: "8.5")
        ], siteID: siteID)
        try db.saveGradeItems([
            MoodleGradeItem(id: 5001, courseID: 100, itemName: "Examen", grade: "7.0", percentage: "70%", feedback: "Bien")
        ], siteID: siteID)
        try db.saveQuizzes([
            MoodleQuiz(id: 701, courseID: 100, name: "Test 1", openDate: Date().addingTimeInterval(-5 * 86400), closeDate: Date().addingTimeInterval(5 * 86400))
        ], siteID: siteID)
        try db.saveQuizAttempts([
            MoodleQuizAttempt(id: 8001, quizID: 701, attemptNumber: 1, state: "finished", sumGrades: 9.0)
        ], siteID: siteID)

        return db
    }
}

/// Parse a tool's JSON string output.
func parseJSON(_ string: String) -> Any? {
    try? JSONSerialization.jsonObject(with: Data(string.utf8))
}
