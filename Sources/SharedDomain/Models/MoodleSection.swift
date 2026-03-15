// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// A section (topic/week) within a Moodle course.
public struct MoodleSection: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let courseID: Int
    public let name: String
    public let summary: String?
    public let sectionNumber: Int
    public let visible: Bool
    public let modules: [MoodleModule]

    public init(
        id: Int,
        courseID: Int,
        name: String,
        summary: String? = nil,
        sectionNumber: Int,
        visible: Bool = true,
        modules: [MoodleModule] = []
    ) {
        self.id = id
        self.courseID = courseID
        self.name = name
        self.summary = summary
        self.sectionNumber = sectionNumber
        self.visible = visible
        self.modules = modules
    }

    /// A sanitized name suitable for use as a folder name.
    public var sanitizedFolderName: String {
        let base = name.isEmpty ? "Section \(sectionNumber)" : name
        return FileNameSanitizer.sanitize(base)
    }
}

/// A module (activity/resource) within a Moodle section.
public struct MoodleModule: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let modName: String
    public let modIcon: URL?
    public let visible: Bool
    public let contents: [MoodleFileContent]

    public init(
        id: Int,
        name: String,
        modName: String,
        modIcon: URL? = nil,
        visible: Bool = true,
        contents: [MoodleFileContent] = []
    ) {
        self.id = id
        self.name = name
        self.modName = modName
        self.modIcon = modIcon
        self.visible = visible
        self.contents = contents
    }

    public var resourceType: ResourceType {
        ResourceType(rawValue: modName) ?? .unknown
    }
}

/// A file content entry within a Moodle module.
public struct MoodleFileContent: Sendable, Codable, Equatable {
    public let type: String // "file", "url", "content"
    public let fileName: String
    public let filePath: String?
    public let fileSize: Int64
    public let fileURL: URL?
    public let timeCreated: Date?
    public let timeModified: Date?
    public let mimeType: String?
    public let author: String?
    public let sortOrder: Int?

    public init(
        type: String,
        fileName: String,
        filePath: String? = nil,
        fileSize: Int64 = 0,
        fileURL: URL? = nil,
        timeCreated: Date? = nil,
        timeModified: Date? = nil,
        mimeType: String? = nil,
        author: String? = nil,
        sortOrder: Int? = nil
    ) {
        self.type = type
        self.fileName = fileName
        self.filePath = filePath
        self.fileSize = fileSize
        self.fileURL = fileURL
        self.timeCreated = timeCreated
        self.timeModified = timeModified
        self.mimeType = mimeType
        self.author = author
        self.sortOrder = sortOrder
    }
}
