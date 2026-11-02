// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import WidgetKit
import SharedDomain

@main
struct FindleWidgets: WidgetBundle {
    var body: some Widget {
        CourseworkWidget()
    }
}

// MARK: - Deadlines and new files

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? .preview : WidgetSnapshot.read() ?? .signedOut))
    }

    /// The app reloads the widget after each sync; past deadlines also drop off
    /// on their own, at the next one.
    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshot.read() ?? .signedOut
        var entries = [SnapshotEntry(date: now, snapshot: snapshot.dropping(before: now))]
        for due in snapshot.deadlines.map(\.due) where due > now {
            entries.append(SnapshotEntry(date: due, snapshot: snapshot.dropping(before: due)))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 60))))
    }
}

struct CourseworkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshot.widgetKind, provider: SnapshotProvider()) { entry in
            CourseworkWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Coursework")
        .description("Upcoming deadlines and files added to your courses.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct CourseworkWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        let snapshot = entry.snapshot
        if snapshot.status == .signedOut {
            message("Open Findle to sign in to Moodle.", symbol: "person.crop.circle.badge.exclamationmark")
        } else if snapshot.deadlines.isEmpty && snapshot.recentFiles.isEmpty {
            message("Nothing due this week and no new files.", symbol: "checkmark.circle")
        } else if family == .systemSmall {
            small(snapshot)
        } else {
            medium(snapshot)
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.callout)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let next = snapshot.deadlines.first {
                Label("Next due", systemImage: "calendar.badge.clock").font(.caption).foregroundStyle(.secondary)
                Text(next.name).font(.headline).lineLimit(2)
                Text(next.due, format: .dateTime.weekday(.abbreviated).hour().minute()).font(.caption)
                Text(next.courseName).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !snapshot.recentFiles.isEmpty {
                Label("\(snapshot.recentFiles.count) new file\(snapshot.recentFiles.count == 1 ? "" : "s")", systemImage: "sparkles")
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL((snapshot.deadlines.first?.itemID ?? snapshot.recentFiles.first?.itemID).flatMap(FindleLinks.reveal(itemID:)))
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Due this week", systemImage: "calendar.badge.clock").font(.caption).foregroundStyle(.secondary)
                if snapshot.deadlines.isEmpty { Text("Nothing due").font(.caption) }
                ForEach(snapshot.deadlines.prefix(3)) { deadline in
                    row(deadline.name, detail: deadline.due.formatted(.dateTime.weekday(.abbreviated).hour().minute()),
                        itemID: deadline.itemID, emphasised: deadline.needsAction)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                Label("Added recently", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                if snapshot.recentFiles.isEmpty { Text("No new files").font(.caption) }
                ForEach(snapshot.recentFiles.prefix(3)) { file in
                    row(file.name, detail: file.courseName, itemID: file.itemID, emphasised: false)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func row(_ title: String, detail: String, itemID: String?, emphasised: Bool) -> some View {
        let content = VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption.weight(emphasised ? .semibold : .regular)).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        if let url = itemID.flatMap(FindleLinks.reveal(itemID:)) {
            Link(destination: url) { content }
        } else {
            content
        }
    }
}

extension WidgetSnapshot {
    /// The same snapshot without deadlines that passed by `date`.
    func dropping(before date: Date) -> WidgetSnapshot {
        var copy = self
        copy.deadlines = deadlines.filter { $0.due > date }
        return copy
    }

    static let preview = WidgetSnapshot(
        status: .upToDate, lastSync: Date(),
        deadlines: [Deadline(id: "1", name: "Lab 3 report", courseName: "Physics", due: Date().addingTimeInterval(86_400),
                             status: "Not submitted", needsAction: true, itemID: nil)],
        recentFiles: [RecentFile(itemID: "a", name: "Lecture 5.pdf", courseName: "Algebra")])
}
