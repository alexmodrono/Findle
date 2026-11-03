// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// A Moodle course visible to the authenticated user.
public struct MoodleCourse: Sendable, Codable, Equatable, Hashable, Identifiable {
    public let id: Int
    public let shortName: String
    public let fullName: String
    public let summary: String?
    public let categoryID: Int?
    public let startDate: Date?
    public let endDate: Date?
    public let lastAccessed: Date?
    public let visible: Bool
    public let siteID: String
    public var customFolderName: String?
    public var customIconName: String?
    public var isSyncEnabled: Bool
    /// The course's Moodle overview/banner image, used as a gallery cover.
    /// Requires the auth token to download (it's a pluginfile URL).
    public var imageURL: URL?
    /// Moodle's course format, such as "weeks" or "topics".
    public var format: String?

    public init(
        id: Int,
        shortName: String,
        fullName: String,
        summary: String? = nil,
        categoryID: Int? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        lastAccessed: Date? = nil,
        visible: Bool = true,
        siteID: String,
        customFolderName: String? = nil,
        customIconName: String? = nil,
        isSyncEnabled: Bool = true,
        imageURL: URL? = nil,
        format: String? = nil
    ) {
        self.id = id
        self.shortName = shortName
        self.fullName = fullName
        self.summary = summary
        self.categoryID = categoryID
        self.startDate = startDate
        self.endDate = endDate
        self.lastAccessed = lastAccessed
        self.visible = visible
        self.siteID = siteID
        self.customFolderName = customFolderName
        self.customIconName = customIconName
        self.isSyncEnabled = isSyncEnabled
        self.imageURL = imageURL
        self.format = format
    }

    /// For a course laid out by weeks, the number of the section covering
    /// `date`: Moodle starts week 1 on the course start date. Nil for other
    /// formats, before the course starts and after it ends.
    public func weekSectionNumber(on date: Date) -> Int? {
        guard format == "weeks", let startDate, date >= startDate else { return nil }
        if let endDate, date > endDate { return nil }
        return Int(date.timeIntervalSince(startDate) / (7 * 24 * 60 * 60)) + 1
    }

    /// A sanitized name suitable for use as a folder name in Finder.
    public var sanitizedFolderName: String {
        FileNameSanitizer.sanitize(fullName)
    }

    /// The folder name to use in Finder, preferring the custom name if set.
    public var effectiveFolderName: String {
        if let custom = trimmedCustomName {
            return FileNameSanitizer.sanitize(custom)
        }
        return sanitizedFolderName
    }

    /// Whether the user has given this course a name of their own.
    public var hasCustomName: Bool {
        trimmedCustomName != nil
    }

    /// The name to show in the app: the user's custom name if set, otherwise
    /// the Moodle full name. Unlike `effectiveFolderName` this is not
    /// sanitized, so it reads exactly as the user typed it.
    public var displayName: String {
        trimmedCustomName ?? fullName
    }

    private var trimmedCustomName: String? {
        guard let trimmed = customFolderName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

// MARK: - Renaming

extension MoodleCourse {
    /// Normalize a proposed custom name before persisting it.
    ///
    /// Returns `nil` (meaning "use the Moodle name") when the proposal is
    /// empty or would produce the same Finder folder as the Moodle name, so
    /// typing the original name back resets the course rather than pinning a
    /// copy that would stop tracking renames on the Moodle side.
    public func normalizedCustomName(_ proposed: String?) -> String? {
        guard let trimmed = proposed?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if FileNameSanitizer.sanitize(trimmed) == sanitizedFolderName {
            return nil
        }
        return trimmed
    }

    /// The first course in `others` whose Finder folder would collide with
    /// this course's folder if it were renamed to `proposed`.
    ///
    /// Course folders are siblings at the root of the File Provider domain,
    /// and the default APFS volume is case-insensitive, so the comparison is
    /// too.
    public func folderNameConflict(
        forProposedName proposed: String?,
        among others: [MoodleCourse]
    ) -> MoodleCourse? {
        var renamed = self
        renamed.customFolderName = normalizedCustomName(proposed)
        let target = renamed.effectiveFolderName
        return others.first { other in
            !(other.id == id && other.siteID == siteID)
                && other.siteID == siteID
                && other.effectiveFolderName.caseInsensitiveCompare(target) == .orderedSame
        }
    }

    /// The File Provider item identifier of this course's root folder.
    public var rootItemID: String {
        Self.rootItemID(siteID: siteID, courseID: id)
    }

    /// The File Provider item identifier of a course's root folder.
    public static func rootItemID(siteID: String, courseID: Int) -> String {
        "course-\(siteID)-\(courseID)"
    }
}
