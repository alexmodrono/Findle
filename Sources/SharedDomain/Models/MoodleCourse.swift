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
    public var isSyncEnabled: Bool

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
        isSyncEnabled: Bool = true
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
        self.isSyncEnabled = isSyncEnabled
    }

    /// A sanitized name suitable for use as a folder name in Finder.
    public var sanitizedFolderName: String {
        FileNameSanitizer.sanitize(fullName)
    }

    /// The folder name to use in Finder, preferring the custom name if set.
    public var effectiveFolderName: String {
        if let custom = customFolderName, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return FileNameSanitizer.sanitize(custom)
        }
        return sanitizedFolderName
    }
}
