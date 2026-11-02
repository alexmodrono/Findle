import XCTest
@testable import SharedDomain

final class FindleLinksTests: XCTestCase {
    func testShowInFindleLinksRoundTrip() throws {
        let url = try XCTUnwrap(FindleLinks.showCourse(42))
        XCTAssertEqual(url.absoluteString, "findle://show?course=42")
        XCTAssertEqual(FindleLinks.shownCourse(in: url), 42)
    }

    func testOtherLinksNameNoCourse() throws {
        XCTAssertNil(FindleLinks.shownCourse(in: try XCTUnwrap(URL(string: "findle://sync?course=42"))))
        XCTAssertNil(FindleLinks.shownCourse(in: try XCTUnwrap(URL(string: "https://show?course=42"))))
        XCTAssertNil(FindleLinks.shownCourse(in: try XCTUnwrap(URL(string: "findle://show?course=abc"))))
    }
}
