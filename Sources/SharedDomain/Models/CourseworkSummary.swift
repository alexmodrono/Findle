// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// The small summary file each assignment and quiz gets in Finder (FX-04):
/// what Quick Look shows, what the thumbnail says and what Spotlight finds.
/// It has its own file type, `.findleassignment` or `.findlequiz`, and is
/// rewritten whenever the coursework changes.
public struct CourseworkSummary: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case assignment, quiz }

    public let kind: Kind
    public let name: String
    public let courseName: String
    /// When an assignment is due, or a quiz closes.
    public let due: Date?
    public let opens: Date?
    public let status: String
    public let grade: String?
    public let brief: String?
    /// Double-clicking the file opens this.
    public let moodleURL: URL?

    public static let assignmentExtension = "findleassignment"
    public static let quizExtension = "findlequiz"
    public static let assignmentType = "com.amodrono.findle.assignment-summary"
    public static let quizType = "com.amodrono.findle.quiz-summary"

    public static func summaryID(for kind: Kind, siteID: String, courseID: Int, moduleID: Int) -> String {
        "\(kind == .assignment ? "assignsum" : "quizsum")-\(siteID)-\(courseID)-\(moduleID)"
    }

    public static func isSummary(_ itemID: String) -> Bool {
        itemID.hasPrefix("assignsum-") || itemID.hasPrefix("quizsum-")
    }

    public static func assignment(name: String, courseName: String, assignment: MoodleAssignment?, brief: String?,
                                  moodleURL: URL?) -> CourseworkSummary {
        let status: String
        if assignment?.graded == true { status = "Graded" }
        else if assignment?.submitted == true { status = "Submitted" }
        else { status = "Not submitted" }
        return CourseworkSummary(kind: .assignment, name: assignment?.name ?? name, courseName: courseName,
                                 due: assignment?.dueDate, opens: nil, status: status, grade: assignment?.grade,
                                 brief: brief.flatMap { $0.isEmpty ? nil : $0 }, moodleURL: moodleURL)
    }

    public static func quiz(name: String, courseName: String, quiz: MoodleQuiz?, attempts: [MoodleQuizAttempt],
                            moodleURL: URL?) -> CourseworkSummary {
        let finished = attempts.filter { $0.state == "finished" }
        let status = finished.isEmpty ? (attempts.contains { $0.state == "inprogress" } ? "In progress" : "Not attempted") : "Attempted"
        let best = finished.compactMap(\.sumGrades).max()
        return CourseworkSummary(kind: .quiz, name: quiz?.name ?? name, courseName: courseName, due: quiz?.closeDate,
                                 opens: quiz?.openDate, status: status,
                                 grade: best.map { $0.formatted(.number.precision(.fractionLength(0...2))) },
                                 brief: nil, moodleURL: moodleURL)
    }

    /// Stable bytes, so an unchanged summary is never rewritten.
    public func encoded() -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return (try? encoder.encode(self)) ?? Data()
    }

    public static func decode(_ data: Data) -> CourseworkSummary? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CourseworkSummary.self, from: data)
    }

    /// What the thumbnail says: the score once graded, otherwise the due date.
    public var headline: String {
        if let grade { return kind == .quiz ? "Score \(grade)" : "Grade \(grade)" }
        if let due { return (kind == .quiz ? "Closes " : "Due ") + due.formatted(.dateTime.day().month(.abbreviated)) }
        return status
    }

    /// A self-contained page for Quick Look.
    public var html: String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var rows: [(String, String)] = [("Course", courseName)]
        if let opens { rows.append(("Opens", opens.formatted(date: .abbreviated, time: .shortened))) }
        if let due { rows.append((kind == .quiz ? "Closes" : "Due", due.formatted(date: .abbreviated, time: .shortened))) }
        rows.append(("Status", status))
        if let grade { rows.append((kind == .quiz ? "Best score" : "Grade", grade)) }
        let table = rows.map { "<tr><th>\(escape($0.0))</th><td>\(escape($0.1))</td></tr>" }.joined()
        let body = brief.map { "<p class=\"brief\">\(escape($0).replacingOccurrences(of: "\n", with: "<br>"))</p>" } ?? ""
        return """
            <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><style>
            body{font:15px -apple-system,sans-serif;margin:32px;color:CanvasText;background:Canvas}
            .kind{color:GrayText;font-size:13px;text-transform:uppercase;letter-spacing:.04em}
            h1{font-size:24px;margin:6px 0 16px}table{border-collapse:collapse}
            th{text-align:left;color:GrayText;font-weight:normal;padding:3px 16px 3px 0}td{padding:3px 0}
            .brief{margin-top:18px;line-height:1.45}
            </style></head><body><div class="kind">\(kind == .assignment ? "Assignment" : "Quiz")</div>
            <h1>\(escape(name))</h1><table>\(table)</table>\(body)</body></html>
            """
    }
}
