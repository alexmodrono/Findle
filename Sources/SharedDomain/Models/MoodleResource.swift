// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// A downloadable resource within a Moodle course.
public struct MoodleResource: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let courseID: Int
    public let sectionID: Int
    public let name: String
    public let resourceType: ResourceType
    public let fileURL: URL?
    public let fileSize: Int64?
    public let mimeType: String?
    public let timeModified: Date?
    public let timeCreated: Date?
    public let siteID: String

    public init(
        id: Int,
        courseID: Int,
        sectionID: Int,
        name: String,
        resourceType: ResourceType,
        fileURL: URL? = nil,
        fileSize: Int64? = nil,
        mimeType: String? = nil,
        timeModified: Date? = nil,
        timeCreated: Date? = nil,
        siteID: String
    ) {
        self.id = id
        self.courseID = courseID
        self.sectionID = sectionID
        self.name = name
        self.resourceType = resourceType
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.mimeType = mimeType
        self.timeModified = timeModified
        self.timeCreated = timeCreated
        self.siteID = siteID
    }

    /// A sanitized filename suitable for display in Finder.
    public var sanitizedFileName: String {
        FileNameSanitizer.sanitize(name, preserveExtension: true)
    }
}

/// The type of a Moodle resource/module.
public enum ResourceType: String, Sendable, Codable, Equatable {
    case file = "resource"
    case folder = "folder"
    case url = "url"
    case page = "page"
    case label = "label"
    case assignment = "assign"
    case forum = "forum"
    case quiz = "quiz"
    case workshop = "workshop"
    case unknown

    /// Whether this resource type can be represented as a downloadable file.
    public var isDownloadable: Bool {
        switch self {
        case .file, .folder:
            return true
        case .url:
            return true // represented as .webloc
        case .page:
            return true // represented as .html or .webarchive
        default:
            return false
        }
    }

    /// Whether this type represents a container (directory).
    public var isContainer: Bool {
        self == .folder
    }
}
