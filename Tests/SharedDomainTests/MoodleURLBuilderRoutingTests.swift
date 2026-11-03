import XCTest
@testable import SharedDomain

final class MoodleURLBuilderRoutingTests: XCTestCase {
    private let base = URL(string: "https://moodle.example.edu")!

    private func url(_ itemID: String, remoteID: Int = 40, directory: Bool = false) -> String {
        MoodleURLBuilder.webURL(baseURL: base, itemID: itemID, courseID: 7, remoteID: remoteID, isDirectory: directory,
                                parentID: nil).absoluteString
    }

    func testSummariesAndSubmitFoldersOpenTheirActivity() {
        XCTAssertTrue(url("quizsum-s-7-40").contains("mod/quiz/view.php?id=40"))
        XCTAssertTrue(url("submit-s-7-40", directory: true).contains("mod/assign/view.php?id=40"))
        XCTAssertTrue(url("assign-s-7-40", directory: true).contains("mod/assign/view.php?id=40"))
    }
}
