import Foundation
import SharedDomain
import Testing

struct FinderFolderResolverTests {
    private let root = URL(fileURLWithPath: "/tmp/FindleNightly-COMILLAS", isDirectory: true)

    private func resolve(_ title: String, _ items: [URL], columns: Bool = false) -> URL? {
        FinderFolderResolver.folderURL(windowTitle: title, itemURLs: items, rootURL: root,
                                       rootNames: ["Findle Nightly"], columnView: columns)
    }

    @Test func contentURLsRecoverTheProviderRootWithItsDisplayName() {
        #expect(resolve("Findle Nightly", [root.appendingPathComponent("Course", isDirectory: true)]) == root)
    }

    @Test func courseAndSectionContextSurviveDecomposedUnicode() {
        let course = root.appendingPathComponent("Electro\u{301}nica", isDirectory: true)
        let section = course.appendingPathComponent("General", isDirectory: true)
        #expect(resolve("Electrónica", [section]) == course)
        #expect(resolve("General", [section.appendingPathComponent("Notes.pdf")]) == section)
    }

    @Test func columnsChooseTheOpenFolderInsteadOfItsParentOrSelectedFile() {
        let course = root.appendingPathComponent("Course", isDirectory: true)
        let section = course.appendingPathComponent("General", isDirectory: true)
        #expect(resolve("General", [course, section, section.appendingPathComponent("Notes.pdf")], columns: true) == section)
        #expect(resolve("General", [course, section], columns: true) == section)
        #expect(resolve("General", [section]) == nil)
    }

    @Test func unrelatedWindowsAndSearchResultsDoNotBorrowFindleContext() {
        let course = root.appendingPathComponent("Course", isDirectory: true)
        let item = course.appendingPathComponent("Notes.pdf")
        #expect(resolve("Recents", [item]) == nil)
        #expect(resolve("Searching This Mac", [item]) == nil)
        #expect(resolve("Course", [URL(fileURLWithPath: "/tmp/other/Course/Notes.pdf")]) == nil)
        #expect(resolve("Course", [URL(fileURLWithPath: "/tmp/FindleNightly-COMILLAS-other/Course/Notes.pdf")]) == nil)
        #expect(resolve("Course", []) == nil)
    }

    @Test func ambiguousSectionNamesDoNotChooseAnArbitraryCourse() {
        let first = root.appendingPathComponent("First/General/Notes.pdf")
        let second = root.appendingPathComponent("Second/General/Notes.pdf")
        #expect(resolve("General", [first, second]) == nil)
    }

    @Test func acceptsNativeAndStringFileURLsButRejectsOtherValues() {
        #expect(FinderFolderResolver.fileURL(root as NSURL) == root)
        #expect(FinderFolderResolver.fileURL(root.absoluteString) == root)
        #expect(FinderFolderResolver.fileURL("https://example.com/Course") == nil)
        #expect(FinderFolderResolver.fileURL("Course") == nil)
        #expect(FinderFolderResolver.fileURL(42) == nil)
        #expect(FinderFolderResolver.fileURL(nil) == nil)
    }

    private func course(_ id: Int, _ name: String, site: String = "site", folder: String? = nil,
                        synced: Bool = true) -> MoodleCourse {
        MoodleCourse(id: id, shortName: "C\(id)", fullName: name, siteID: site,
                     customFolderName: folder, isSyncEnabled: synced)
    }

    @Test func courseFolderMatchesOnlyItsOwnSite() {
        let courses = [course(1, "Calculus", site: "other"), course(2, "Calculus")]
        #expect(FinderFolderResolver.course(folderName: "Calculus", siteID: "site", in: courses)?.id == 2)
        #expect(FinderFolderResolver.course(folderName: "Calculus", siteID: "missing", in: courses) == nil)
        #expect(FinderFolderResolver.course(folderName: "Calculus", siteID: nil, in: courses) == nil)
    }

    @Test func sharedCourseFolderNamesNeverGuessACourse() {
        let twins = [course(1, "Calculus"), course(2, "Calculus")]
        #expect(FinderFolderResolver.course(folderName: "Calculus", siteID: "site", in: twins) == nil)
        // File Provider shows the second one under a different name; that name isn't a course.
        #expect(FinderFolderResolver.course(folderName: "Calculus 2", siteID: "site", in: twins) == nil)
        // Names that only differ after sanitizing collide too.
        let sanitized = [course(3, "Lab: Week 1"), course(4, "Lab/ Week 1")]
        #expect(sanitized[0].effectiveFolderName == "Lab- Week 1")
        #expect(sanitized[1].effectiveFolderName == "Lab- Week 1")
        #expect(FinderFolderResolver.course(folderName: "Lab- Week 1", siteID: "site", in: sanitized) == nil)
    }

    @Test func theOnlySyncedCourseOwnsASharedFolderName() {
        let courses = [course(1, "Calculus", synced: false), course(2, "Calculus")]
        #expect(FinderFolderResolver.course(folderName: "Calculus", siteID: "site", in: courses)?.id == 2)
        let unsynced = [course(1, "Calculus", synced: false), course(2, "Calculus", synced: false)]
        #expect(FinderFolderResolver.course(folderName: "Calculus", siteID: "site", in: unsynced) == nil)
    }

    @Test func renamedCourseFoldersFollowTheNewName() {
        var renamed = course(1, "Operating Systems", folder: "OS")
        #expect(FinderFolderResolver.course(folderName: "OS", siteID: "site", in: [renamed])?.id == 1)
        // A Finder window still showing the old path must not keep the course.
        #expect(FinderFolderResolver.course(folderName: "Operating Systems", siteID: "site", in: [renamed]) == nil)
        renamed.customFolderName = "  "
        #expect(FinderFolderResolver.course(folderName: "Operating Systems", siteID: "site", in: [renamed])?.id == 1)
        // A rename onto another course's name makes both ambiguous.
        let clash = [course(1, "Operating Systems", folder: "Physics"), course(2, "Physics")]
        #expect(FinderFolderResolver.course(folderName: "Physics", siteID: "site", in: clash) == nil)
    }

    @Test func decomposedFinderNamesMatchComposedCourseNames() {
        let courses = [course(1, "Electrónica")]
        #expect(FinderFolderResolver.course(folderName: "Electro\u{301}nica", siteID: "site", in: courses)?.id == 1)
    }
}
