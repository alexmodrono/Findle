// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// A compact, token-safe snapshot of Moodle's course structure. It deliberately
/// omits authenticated URLs and full document contents while preserving the
/// section/activity metadata that the Finder projection does not need.
public struct CourseOutlineSnapshot: Sendable, Codable, Equatable {
    public let courseID: Int
    public let capturedAt: Date
    public let sections: [CourseOutlineSection]

    public init(
        courseID: Int,
        capturedAt: Date = Date(),
        sections: [CourseOutlineSection]
    ) {
        self.courseID = courseID
        self.capturedAt = capturedAt
        self.sections = sections
    }

    public init(courseID: Int, sections: [MoodleSection], capturedAt: Date = Date()) {
        self.init(
            courseID: courseID,
            capturedAt: capturedAt,
            sections: sections.map(CourseOutlineSection.init)
        )
    }
}

public struct CourseOutlineSection: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let summary: String?
    public let sectionNumber: Int
    public let visible: Bool
    public let modules: [CourseOutlineModule]

    public init(
        id: Int,
        name: String,
        summary: String? = nil,
        sectionNumber: Int,
        visible: Bool = true,
        modules: [CourseOutlineModule] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.sectionNumber = sectionNumber
        self.visible = visible
        self.modules = modules
    }

    init(_ section: MoodleSection) {
        self.init(
            id: section.id,
            name: section.name,
            summary: section.summary,
            sectionNumber: section.sectionNumber,
            visible: section.visible,
            modules: section.modules.map(CourseOutlineModule.init)
        )
    }
}

public struct CourseOutlineModule: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let name: String
    public let type: String
    public let visible: Bool
    public let files: [CourseOutlineFile]

    public init(
        id: Int,
        name: String,
        type: String,
        visible: Bool = true,
        files: [CourseOutlineFile] = []
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.visible = visible
        self.files = files
    }

    init(_ module: MoodleModule) {
        self.init(
            id: module.id,
            name: module.name,
            type: module.modName,
            visible: module.visible,
            files: module.contents.map(CourseOutlineFile.init)
        )
    }
}

public struct CourseOutlineFile: Sendable, Codable, Equatable {
    public let name: String
    public let type: String
    public let size: Int64
    public let mimeType: String?
    public let modified: Date?
    public let sortOrder: Int?

    public init(
        name: String,
        type: String,
        size: Int64 = 0,
        mimeType: String? = nil,
        modified: Date? = nil,
        sortOrder: Int? = nil
    ) {
        self.name = name
        self.type = type
        self.size = size
        self.mimeType = mimeType
        self.modified = modified
        self.sortOrder = sortOrder
    }

    init(_ content: MoodleFileContent) {
        self.init(
            name: content.fileName,
            type: content.type,
            size: content.fileSize,
            mimeType: content.mimeType,
            modified: content.timeModified,
            sortOrder: content.sortOrder
        )
    }
}
