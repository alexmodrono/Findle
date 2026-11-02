import XCTest
@testable import SharedDomain

/// Quick Look's summary of H5P and SCORM packages, from real zip archives.
final class PackageSummaryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("packages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Zips `files` with /usr/bin/zip; `stored` keeps them uncompressed.
    private func zip(_ files: [String: Data], stored: Bool = false) throws -> Data {
        let root = directory.appendingPathComponent(UUID().uuidString)
        for (path, data) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        let output = directory.appendingPathComponent(UUID().uuidString + ".zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = root
        process.arguments = (stored ? ["-0"] : []) + ["-qr", output.path] + files.keys.sorted()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try Data(contentsOf: output)
    }

    func testAnH5PPackageShowsItsTitleTypeAndFirstImage() throws {
        let manifest = #"{"title":"Cell biology video","mainLibrary":"H5P.InteractiveVideo","language":"en","authors":[{"name":"Dr. Ruiz","role":"Author"}],"license":"CC BY"}"#
        let image = Data(repeating: 7, count: 3000)
        for stored in [false, true] {
            let summary = try PackageSummary.read(zip(["h5p.json": Data(manifest.utf8), "content/content.json": Data("{}".utf8),
                                                       "content/images/b.png": image, "content/images/a.jpg": image], stored: stored))
            XCTAssertEqual(summary.kind, .h5p)
            XCTAssertEqual(summary.title, "Cell biology video")
            XCTAssertEqual(summary.activityType, "Interactive Video")
            XCTAssertEqual(summary.details, ["Language: en", "By Dr. Ruiz", "License: CC BY"])
            XCTAssertEqual(summary.image?.data, image, "Deflated and stored entries read the same")
            XCTAssertEqual(summary.image?.mimeType, "image/jpeg", "The first image by name")
            XCTAssertTrue(summary.html.contains("Cell biology video"))
        }
    }

    func testAScormPackageShowsItsTitleAndVersion() throws {
        let manifest = """
            <?xml version="1.0"?><manifest xmlns="http://www.imsglobal.org/xsd/imscp_v1p1">
            <metadata><schema>ADL SCORM</schema><schemaversion>2004 4th Edition</schemaversion></metadata>
            <organizations><organization identifier="o"><title>Lab safety &amp; rules</title>
            <item identifier="i1"><title>Intro</title></item><item identifier="i2"><title>Quiz</title></item>
            </organization></organizations></manifest>
            """
        let summary = try PackageSummary.read(zip(["imsmanifest.xml": Data(manifest.utf8), "index.html": Data("<p>".utf8)]))
        XCTAssertEqual(summary.kind, .scorm)
        XCTAssertEqual(summary.title, "Lab safety & rules")
        XCTAssertEqual(summary.activityType, "SCORM 2004")
        XCTAssertEqual(summary.details, ["2 parts"])
        XCTAssertTrue(summary.html.contains("Lab safety &amp; rules"), "Text is escaped in the page")
    }

    func testOtherOrDamagedFilesThrowInsteadOfCrashing() throws {
        XCTAssertThrowsError(try PackageSummary.read(zip(["readme.txt": Data("hi".utf8)])))
        XCTAssertThrowsError(try PackageSummary.read(Data("not a zip at all".utf8)))
        var damaged = try zip(["h5p.json": Data(#"{"title":"x","mainLibrary":"H5P.Blanks"}"#.utf8)])
        damaged.replaceSubrange(10..<40, with: Data(repeating: 0, count: 30))
        XCTAssertThrowsError(try PackageSummary.read(damaged))
        XCTAssertThrowsError(try PackageSummary.read(zip(["h5p.json": Data("not json".utf8)])))
    }

    func testLibraryNamesReadLikeTheirActivity() {
        XCTAssertEqual(PackageSummary.humanize("H5P.InteractiveVideo"), "Interactive Video")
        XCTAssertEqual(PackageSummary.humanize("H5P.DragQuestion"), "Drag Question")
        XCTAssertEqual(PackageSummary.humanize(""), "Interactive content")
    }
}
