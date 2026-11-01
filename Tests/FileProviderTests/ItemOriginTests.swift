import XCTest
import FileProvider
import SharedDomain

/// Get Info's "Where from" and the author, which the system writes on each file
/// from the item's extended attributes.
final class ItemOriginTests: XCTestCase {
    private let site = MoodleSite(id: "origin-site", displayName: "Moodle", baseURL: URL(string: "https://moodle.test")!)

    override func setUp() {
        MoodleSiteLinks.register(site)
    }

    private func item(_ id: String, parent: String = "section-origin-site-1-2", remoteID: Int = 7, directory: Bool = false,
                      personal: Bool = false, author: String? = nil, site: String = "origin-site") -> FileProviderItem {
        FileProviderItem(localItem: LocalItem(id: id, parentID: parent, siteID: site, courseID: 1, remoteID: remoteID,
                                              filename: id, isDirectory: directory, isLocal: personal, author: author))
    }

    private func strings(_ item: FileProviderItem, _ attribute: String) throws -> [String]? {
        guard let data = item.extendedAttributes[attribute] else { return nil }
        return try PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
    }

    func testSyncedFilesSayWhereOnMoodleTheyCameFromAndWho() throws {
        let resource = item("file-origin-site-1-7-notes.pdf", author: "Prof. Smith")
        XCTAssertEqual(try strings(resource, FileProviderItem.whereFromsAttribute), ["https://moodle.test/mod/resource/view.php?id=7"])
        XCTAssertEqual(try strings(resource, FileProviderItem.authorsAttribute), ["Prof. Smith"])

        let inFolder = item("file-origin-site-1-9-lab.pdf", parent: "folder-origin-site-1-9", remoteID: 9)
        XCTAssertEqual(try strings(inFolder, FileProviderItem.whereFromsAttribute), ["https://moodle.test/mod/folder/view.php?id=9"],
                       "A file in a folder module opens that folder")
        XCTAssertNil(inFolder.extendedAttributes[FileProviderItem.authorsAttribute])

        let attachment = item("file-origin-site-1-4-rubric.pdf", parent: "assign-origin-site-1-4", remoteID: 4)
        XCTAssertEqual(try strings(attachment, FileProviderItem.whereFromsAttribute), ["https://moodle.test/mod/assign/view.php?id=4"])

        let course = item("course-origin-site-1", parent: "", remoteID: 1, directory: true)
        XCTAssertEqual(try strings(course, FileProviderItem.whereFromsAttribute), ["https://moodle.test/course/view.php?id=1"])
    }

    func testPersonalFilesShowNothingExtra() {
        XCTAssertEqual(item("local-essay", personal: true, author: "Me").extendedAttributes, [:])
        XCTAssertEqual(item("file-x", site: "unregistered").extendedAttributes, [:], "No link without the site's address")
    }

    func testANewLinkOrAuthorReachesTheSystemAsNewMetadata() {
        let before = item("file-origin-site-1-7-notes.pdf").itemVersion
        let withAuthor = item("file-origin-site-1-7-notes.pdf", author: "Prof. Smith").itemVersion
        let moved = item("file-origin-site-1-7-notes.pdf", parent: "folder-origin-site-1-7").itemVersion
        XCTAssertNotEqual(withAuthor.metadataVersion, before.metadataVersion)
        XCTAssertNotEqual(moved.metadataVersion, before.metadataVersion)
        XCTAssertEqual(withAuthor.contentVersion, before.contentVersion)
    }
}
