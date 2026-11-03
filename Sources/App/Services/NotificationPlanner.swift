// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SharedDomain

/// Works out which notifications carry news: files a sync brought in, an
/// assignment about to be due, a grade posted. Nothing here fires for a sync
/// without changes, and the first sync of a course is a baseline (no arrivals
/// are recorded for it), so setting up doesn't flood the user.
enum NotificationPlanner {
    enum Kind: String, CaseIterable {
        case newFiles, dueSoon, grades

        /// The General settings switch for this kind, on unless turned off.
        var defaultsKey: String {
            switch self {
            case .newFiles: "notifyNewFiles"
            case .dueSoon: "notifyDueSoon"
            case .grades: "notifyGrades"
            }
        }
    }

    struct Notice: Equatable {
        let kind: Kind
        let id: String
        let title: String
        let body: String
        /// Revealed in Finder when the notification is clicked.
        let itemID: String?
        let threadID: String
    }

    /// How far ahead an assignment is announced as due.
    static let dueSoonWindow: TimeInterval = 24 * 60 * 60

    /// One notification per course, naming the first few files.
    static func newFiles(arrived: [LocalItem], courses: [MoodleCourse]) -> [Notice] {
        let files = arrived.filter { !$0.isDirectory && !$0.isLocal && !$0.isInFinderCollection }
        return Dictionary(grouping: files, by: \.courseID).sorted { $0.key < $1.key }.compactMap { courseID, items in
            guard let course = courses.first(where: { $0.id == courseID }) else { return nil }
            let names = items.map(\.filename).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let body: String
            switch names.count {
            case 1: body = names[0]
            case 2: body = "\(names[0]) and \(names[1])"
            default: body = "\(names[0]), \(names[1]) and \(names.count - 2) more"
            }
            let sorted = items.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
            return Notice(kind: .newFiles, id: "new-\(courseID)-\(sorted.map(\.id).joined(separator: ",").hashValue)",
                          title: names.count == 1 ? "New in \(course.fullName)" : "\(names.count) new files in \(course.fullName)",
                          body: body, itemID: sorted.first?.id, threadID: "course-\(courseID)")
        }
    }

    /// Unsubmitted assignments due within a day, each announced once (`announced`
    /// holds the keys of those already announced, which change with the due date).
    static func dueSoon(assignments: [MoodleAssignment], courses: [MoodleCourse], siteID: String, now: Date,
                        announced: Set<String>) -> (notices: [Notice], keys: Set<String>) {
        var notices: [Notice] = []
        var keys = Set<String>()
        for assignment in assignments.sorted(by: { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) {
            guard !assignment.submitted, let due = assignment.dueDate, due > now, due <= now.addingTimeInterval(dueSoonWindow),
                  let course = courses.first(where: { $0.id == assignment.courseID && $0.isSyncEnabled }) else { continue }
            let key = "\(siteID):\(assignment.id):\(Int(due.timeIntervalSince1970))"
            keys.insert(key)
            guard !announced.contains(key) else { continue }
            notices.append(Notice(
                kind: .dueSoon, id: "due-\(key)", title: "\(assignment.name) is due soon",
                body: "\(course.fullName) · Due \(due.formatted(date: .omitted, time: .shortened))",
                itemID: assignment.moduleID.map { "assign-\(siteID)-\(assignment.courseID)-\($0)" },
                threadID: "course-\(assignment.courseID)"))
        }
        return (notices, keys)
    }

    /// Assignments graded since the last refresh. Without an earlier refresh
    /// there is nothing to compare, so nothing is announced.
    static func gradesPosted(before: [MoodleAssignment], after: [MoodleAssignment], courses: [MoodleCourse],
                             siteID: String) -> [Notice] {
        guard !before.isEmpty else { return [] }
        let previous = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return after.compactMap { assignment in
            guard assignment.graded, let old = previous[assignment.id], !old.graded || old.grade != assignment.grade,
                  let course = courses.first(where: { $0.id == assignment.courseID && $0.isSyncEnabled }) else { return nil }
            return Notice(
                kind: .grades, id: "grade-\(siteID)-\(assignment.id)-\(assignment.grade ?? "")",
                title: "Grade posted: \(assignment.name)",
                body: [course.fullName, assignment.grade].compactMap { $0 }.joined(separator: " · "),
                itemID: assignment.moduleID.map { "assign-\(siteID)-\(assignment.courseID)-\($0)" },
                threadID: "course-\(assignment.courseID)")
        }
    }
}
