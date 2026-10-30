import XCTest

final class CIEventQualificationTests: XCTestCase {
    func testControlledForkFailureReachesRequiredCI() {
        XCTFail("Intentional fork CI qualification failure; this branch must never be merged")
    }
}
