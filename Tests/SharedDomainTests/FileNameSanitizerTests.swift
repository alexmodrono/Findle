import XCTest
@testable import SharedDomain

final class FileNameSanitizerTests: XCTestCase {

    func testBasicSanitization() {
        XCTAssertEqual(FileNameSanitizer.sanitize("Hello World"), "Hello World")
    }

    func testSlashReplacement() {
        XCTAssertEqual(FileNameSanitizer.sanitize("Fall 2024/Spring"), "Fall 2024-Spring")
    }

    func testColonReplacement() {
        XCTAssertEqual(FileNameSanitizer.sanitize("Week 1: Introduction"), "Week 1- Introduction")
    }

    func testLeadingDotRemoval() {
        XCTAssertEqual(FileNameSanitizer.sanitize(".hidden"), "hidden")
        XCTAssertEqual(FileNameSanitizer.sanitize("...multiple"), "multiple")
    }

    func testWhitespaceTriming() {
        XCTAssertEqual(FileNameSanitizer.sanitize("  spaces  "), "spaces")
    }

    func testEmptyStringFallback() {
        XCTAssertEqual(FileNameSanitizer.sanitize(""), "Untitled")
        XCTAssertEqual(FileNameSanitizer.sanitize("..."), "Untitled")
    }

    func testPreserveExtension() {
        let result = FileNameSanitizer.sanitize("document.pdf", preserveExtension: true)
        XCTAssertTrue(result.hasSuffix(".pdf"))
    }

    func testSpecialCharacters() {
        let result = FileNameSanitizer.sanitize("Lecture 1: Data/Types\0")
        XCTAssertFalse(result.contains("/"))
        XCTAssertFalse(result.contains(":"))
        XCTAssertFalse(result.contains("\0"))
    }

    func testCollapsedDashes() {
        // "a//b" -> "a--b" -> "a-b"
        XCTAssertEqual(FileNameSanitizer.sanitize("a//b"), "a-b")
    }

    func testLongName() {
        let longName = String(repeating: "a", count: 300)
        let result = FileNameSanitizer.sanitize(longName)
        XCTAssertLessThanOrEqual(result.utf8.count, 200)
    }
}
