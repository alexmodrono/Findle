import XCTest
@testable import SharedDomain

final class MoodleTextTests: XCTestCase {
    func testParagraphsListsAndBreaksBecomeLines() {
        let html = "<h3>Week 1</h3><p>Read <b>chapter 2</b>.<br/>Bring notes.</p><ul><li>Laptop</li><li>Charger</li></ul>"
        XCTAssertEqual(MoodleText.plainText(fromHTML: html), "Week 1\n\nRead chapter 2.\nBring notes.\n\n- Laptop\n- Charger")
    }

    func testEntitiesAreDecodedAndSpacesCollapsed() {
        XCTAssertEqual(MoodleText.plainText(fromHTML: "Fish &amp; chips&nbsp;&nbsp;at 5 &#8211; 6 &#x2014; ok &bogus;"),
                       "Fish & chips at 5 – 6 — ok &bogus;")
    }

    func testWebLinksKeepTheirAddressButMoodleFileLinksDoNot() {
        let html = #"<a href="https://example.org/guide">the guide</a>, <a href="https://moodle.test/pluginfile.php/1/x.pdf">slides</a>, <a href="https://moodle.test/x?token=abc">here</a>, <a href="https://example.org/">https://example.org/</a>"#
        XCTAssertEqual(MoodleText.plainText(fromHTML: html), "the guide (https://example.org/guide), slides, here, https://example.org/")
    }

    func testScriptsStylesAndEmptyMarkupDisappear() {
        XCTAssertEqual(MoodleText.plainText(fromHTML: "<style>p{}</style><script>alert(1)</script><p></p><p> </p>"), "")
        XCTAssertEqual(MoodleText.plainText(fromHTML: "<img src=\"x.png\"><p>Only text</p>"), "Only text")
    }
}
