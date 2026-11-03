// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
@testable import SharedDomain

final class CourseCustomizationTests: XCTestCase {
    private let course = MoodleCourse(id: 1, shortName: "OS", fullName: "Operating Systems", siteID: "site-1")

    // MARK: - Display name

    func testDisplayNameFallsBackToMoodleName() {
        XCTAssertEqual(course.displayName, "Operating Systems")
        XCTAssertFalse(course.hasCustomName)
    }

    func testDisplayNameUsesTrimmedCustomName() {
        var renamed = course
        renamed.customFolderName = "  OS 2026  "
        XCTAssertEqual(renamed.displayName, "OS 2026")
        XCTAssertTrue(renamed.hasCustomName)
        XCTAssertEqual(renamed.effectiveFolderName, "OS 2026")
    }

    func testBlankCustomNameIsIgnored() {
        var renamed = course
        renamed.customFolderName = "   "
        XCTAssertEqual(renamed.displayName, "Operating Systems")
        XCTAssertFalse(renamed.hasCustomName)
    }

    func testDisplayNameIsNotSanitized() {
        var renamed = course
        renamed.customFolderName = "OS: Part 1/2"
        XCTAssertEqual(renamed.displayName, "OS: Part 1/2")
        XCTAssertFalse(renamed.effectiveFolderName.contains(":"))
        XCTAssertFalse(renamed.effectiveFolderName.contains("/"))
    }

    // MARK: - Normalization

    func testNormalizedCustomNameTrims() {
        XCTAssertEqual(course.normalizedCustomName("  Kernels  "), "Kernels")
    }

    func testNormalizedCustomNameResetsOnEmptyOrMoodleName() {
        XCTAssertNil(course.normalizedCustomName(nil))
        XCTAssertNil(course.normalizedCustomName(""))
        XCTAssertNil(course.normalizedCustomName("   "))
        XCTAssertNil(course.normalizedCustomName("Operating Systems"))
        XCTAssertNil(course.normalizedCustomName(" Operating Systems "))
    }

    func testNormalizedCustomNameTreatsSanitizedMoodleNameAsReset() {
        let colonCourse = MoodleCourse(id: 2, shortName: "CS", fullName: "CS: Intro", siteID: "site-1")
        // Finder hands back the sanitized folder name on a no-op rename.
        XCTAssertNil(colonCourse.normalizedCustomName(colonCourse.sanitizedFolderName))
    }

    // MARK: - Conflicts

    func testFolderNameConflictDetectsCaseInsensitiveCollision() {
        let other = MoodleCourse(id: 2, shortName: "DB", fullName: "Databases", siteID: "site-1")
        let conflict = course.folderNameConflict(forProposedName: "databases", among: [course, other])
        XCTAssertEqual(conflict?.id, other.id)
    }

    func testFolderNameConflictDetectsCollisionWithCustomName() {
        var other = MoodleCourse(id: 2, shortName: "DB", fullName: "Databases", siteID: "site-1")
        other.customFolderName = "Kernels"
        XCTAssertEqual(course.folderNameConflict(forProposedName: "Kernels", among: [other])?.id, other.id)
    }

    func testFolderNameConflictIgnoresSelfAndOtherSites() {
        let elsewhere = MoodleCourse(id: 2, shortName: "DB", fullName: "Databases", siteID: "site-2")
        XCTAssertNil(course.folderNameConflict(forProposedName: "Operating Systems", among: [course]))
        XCTAssertNil(course.folderNameConflict(forProposedName: "Databases", among: [course, elsewhere]))
    }

    // MARK: - Root items

    func testRootItemIDMatchesLocalItemCourseRoot() {
        let root = LocalItem(
            id: course.rootItemID,
            parentID: nil,
            siteID: course.siteID,
            courseID: course.id,
            remoteID: course.id,
            filename: course.effectiveFolderName,
            isDirectory: true
        )
        XCTAssertEqual(course.rootItemID, "course-site-1-1")
        XCTAssertTrue(root.isCourseRoot)
    }

    func testSectionsAndLocalFoldersAreNotCourseRoots() {
        let section = LocalItem(
            id: "section-site-1-1-11",
            parentID: course.rootItemID,
            siteID: course.siteID,
            courseID: course.id,
            remoteID: 11,
            filename: "Week 1",
            isDirectory: true
        )
        let localFolder = LocalItem(
            id: course.rootItemID,
            parentID: nil,
            siteID: course.siteID,
            courseID: course.id,
            remoteID: 0,
            filename: "Mine",
            isDirectory: true,
            isLocal: true
        )
        XCTAssertFalse(section.isCourseRoot)
        XCTAssertFalse(localFolder.isCourseRoot)
    }

    // MARK: - Tags

    func testDistinctTagsDedupeCaseInsensitivelyAndSort() {
        let tags = FinderTag.distinct(in: [
            [FinderTag(name: "Exams", color: .red), FinderTag(name: "Labs", color: .green)],
            [FinderTag(name: "exams", color: .blue), FinderTag(name: "Archive", color: .gray)],
        ])
        XCTAssertEqual(tags.map(\.name), ["Archive", "Exams", "Labs"])
        // First occurrence wins.
        XCTAssertEqual(tags.first { $0.name == "Exams" }?.color, .red)
    }

    func testExistingTagMatchesTrimmedNameIgnoringCase() {
        let known = [FinderTag(name: "Exams", color: .red)]
        XCTAssertEqual(FinderTag.existing(named: "  exams ", in: known), known[0])
        XCTAssertNil(FinderTag.existing(named: "Exam", in: known))
    }
}
