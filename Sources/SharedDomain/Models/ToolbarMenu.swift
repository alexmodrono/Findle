// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// The menu of Findle's button in Finder's toolbar: courses, upcoming
/// deadlines, Sync Now and Settings. Each entry opens a findle:// link the app
/// handles, so the Finder Sync extension needs nothing but the snapshot.
public enum ToolbarMenu {
    public enum Entry: Equatable {
        case action(String, URL)
        case header(String)
        case separator
    }

    public static func entries(for snapshot: WidgetSnapshot?) -> [Entry] {
        guard let snapshot, snapshot.status != .signedOut else {
            return [.action("Sign In to Findle…", FindleLinks.settings)]
        }
        var entries: [Entry] = [.action(snapshot.status == .syncing ? "Syncing…" : "Sync Now", FindleLinks.sync)]
        if !snapshot.deadlines.isEmpty {
            entries += [.separator, .header("Due This Week")]
            for deadline in snapshot.deadlines.prefix(5) {
                let title = "\(deadline.name) — \(deadline.due.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
                entries.append(.action(title, deadline.itemID.flatMap(FindleLinks.reveal(itemID:)) ?? FindleLinks.settings))
            }
        }
        let courses = snapshot.courses ?? []
        if !courses.isEmpty {
            entries += [.separator, .header("Courses")]
            entries += courses.compactMap { course in FindleLinks.openCourse(course.id).map { .action(course.name, $0) } }
        }
        entries += [.separator, .action("Findle Settings…", FindleLinks.settings)]
        return entries
    }
}
