import Foundation
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
}
