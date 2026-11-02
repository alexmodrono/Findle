// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// What Findle keeps downloaded on its own: the section of each weekly course
/// that covers today, so what is needed for class is offline (FI-16).
public enum CurrentWeek {
    /// The Settings switch, on unless turned off.
    public static let defaultsKey = "keepCurrentWeekDownloaded"

    /// The current week's section of `course` and everything in it, from Moodle.
    public static func itemIDs(course: MoodleCourse, outline: CourseOutlineSnapshot?, items: [LocalItem],
                               now: Date) -> Set<String> {
        guard course.isSyncEnabled, let week = course.weekSectionNumber(on: now),
              let section = outline?.sections.first(where: { $0.sectionNumber == week }) else { return [] }
        let root = "section-\(course.siteID)-\(course.id)-\(section.id)"
        let children = Dictionary(grouping: items.filter { !$0.isLocal && $0.courseID == course.id }, by: \.parentID)
        guard items.contains(where: { $0.id == root }) else { return [] }
        var kept: Set<String> = [root]
        var frontier = [root]
        while let id = frontier.popLast() {
            for child in children[id] ?? [] where kept.insert(child.id).inserted {
                frontier.append(child.id)
            }
        }
        return kept
    }
}
