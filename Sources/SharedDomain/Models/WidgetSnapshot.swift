// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// What the desktop widget and the Control Center control show. The app writes
/// it to the App Group container after syncs and coursework refreshes; the
/// widget extension only reads it, so it never needs the database.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable {
        case upToDate, syncing, needsAttention, signedOut
    }

    public struct Deadline: Codable, Sendable, Equatable, Identifiable {
        public let id: String
        public let name: String
        public let courseName: String
        public let due: Date
        public let status: String
        public let needsAction: Bool
        /// Revealed in Finder when the entry is clicked.
        public let itemID: String?

        public init(id: String, name: String, courseName: String, due: Date, status: String, needsAction: Bool, itemID: String?) {
            self.id = id
            self.name = name
            self.courseName = courseName
            self.due = due
            self.status = status
            self.needsAction = needsAction
            self.itemID = itemID
        }
    }

    public struct RecentFile: Codable, Sendable, Equatable, Identifiable {
        public let itemID: String
        public let name: String
        public let courseName: String
        public var id: String { itemID }

        public init(itemID: String, name: String, courseName: String) {
            self.itemID = itemID
            self.name = name
            self.courseName = courseName
        }
    }

    public var status: Status
    public var lastSync: Date?
    public var deadlines: [Deadline]
    public var recentFiles: [RecentFile]

    public init(status: Status, lastSync: Date? = nil, deadlines: [Deadline] = [], recentFiles: [RecentFile] = []) {
        self.status = status
        self.lastSync = lastSync
        self.deadlines = deadlines
        self.recentFiles = recentFiles
    }

    public static let signedOut = WidgetSnapshot(status: .signedOut)

    public static let widgetKind = "\(BundleIdentifiers.prefix).widget.coursework"
    public static let controlKind = "\(BundleIdentifiers.prefix).control.sync"

    /// Where the app writes the snapshot, or nil when the system withholds the
    /// App Group container (an unsigned or differently signed build).
    public static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: BundleIdentifiers.appGroup)?
            .appendingPathComponent("widget-snapshot.json")
    }

    public static func read(from url: URL? = fileURL) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func write(to url: URL? = fileURL) throws {
        guard let url else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
