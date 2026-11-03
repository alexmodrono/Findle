import AppKit
import WebKit
import XCTest
@testable import SharedDomain
@testable import FindleNetworking

/// Pages are saved with their images, so they open offline and preview with Quick Look.
final class PageArchiverTests: XCTestCase {
    private let site = MoodleSite(id: "s", displayName: "Campus", baseURL: URL(string: "https://moodle.example.edu")!)
    private let pageURL = URL(string: "https://moodle.example.edu/webservice/pluginfile.php/12/mod_page/content/3/index.html")!

    private func origin() throws -> AuthenticatedRequestOrigin { try AuthenticatedRequestOrigin(site: site) }

    func testOnlyThePagesOwnImagesAreFetchedWithTheToken() throws {
        let html = """
            <p><img src="diagram.png" alt="x"><img class="a" src='sub/photo%201.jpg'>
            <img src="https://moodle.example.edu/pluginfile.php/12/mod_page/content/3/old.gif">
            <img src="https://elsewhere.example.com/logo.png"><img src="data:image/png;base64,AAAA">
            <img src="diagram.png"><img src="https://moodle.example.edu/course/view.php?id=4">
            <img src="https://moodle.example.edu/pluginfile.php/1/x.png?token=abc"></p>
            """
        let found = PageArchiver.resources(in: html, pageURL: pageURL, origin: try origin())
        XCTAssertEqual(found.map(\.archived.absoluteString), [
            "https://moodle.example.edu/webservice/pluginfile.php/12/mod_page/content/3/diagram.png",
            "https://moodle.example.edu/webservice/pluginfile.php/12/mod_page/content/3/sub/photo%201.jpg",
            "https://moodle.example.edu/pluginfile.php/12/mod_page/content/3/old.gif",
        ], "Other sites, inline data, repeats, non-file pages and URLs carrying credentials are left alone")
        XCTAssertEqual(found.last?.fetch.absoluteString,
                       "https://moodle.example.edu/webservice/pluginfile.php/12/mod_page/content/3/old.gif",
                       "A browser link to a Moodle file is fetched through the web service")
    }

    func testTheArchiveIsAWebArchiveWithItsImages() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        let imageURL = URL(string: "diagram.png", relativeTo: pageURL)!.absoluteURL
        let data = try PageArchiver.archive(html: Data(#"<img src="diagram.png">"#.utf8), pageURL: pageURL, textEncoding: nil,
                                            resources: [.init(url: imageURL, data: png, mimeType: "image/png")])

        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let main = try XCTUnwrap(plist["WebMainResource"] as? [String: Any])
        XCTAssertEqual(main["WebResourceURL"] as? String, pageURL.absoluteString)
        XCTAssertEqual(main["WebResourceMIMEType"] as? String, "text/html")
        let subresources = try XCTUnwrap(plist["WebSubresources"] as? [[String: Any]])
        XCTAssertEqual(subresources.first?["WebResourceURL"] as? String, imageURL.absoluteString)
        XCTAssertEqual(subresources.first?["WebResourceData"] as? Data, png)
    }

    func testOnlyPagesSavedAsArchivesTakeThisPath() {
        let page = LocalItem(id: "page-s-1-3", siteID: "s", courseID: 1, remoteID: 3, filename: "Welcome.webarchive")
        let older = LocalItem(id: "page-s-1-3", siteID: "s", courseID: 1, remoteID: 3, filename: "Welcome.html")
        let file = LocalItem(id: "file-s-1-3-a", siteID: "s", courseID: 1, remoteID: 3, filename: "a.webarchive")
        XCTAssertTrue(PageArchiver.isPage(page))
        XCTAssertFalse(PageArchiver.isPage(older))
        XCTAssertFalse(PageArchiver.isPage(file))
    }
}
