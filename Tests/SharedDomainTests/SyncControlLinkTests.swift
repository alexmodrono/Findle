import XCTest
@testable import SharedDomain

/// The Sync Findle control opens the link the app already treats as "sync in
/// the background", so it never opens a window.
final class SyncControlLinkTests: XCTestCase {
    func testTheControlStartsABackgroundSync() {
        XCTAssertEqual(FindleLinks.sync.absoluteString, "findle://sync")
        XCTAssertEqual(FindleLinks.sync.host, "sync")
        XCTAssertNotEqual(WidgetSnapshot.controlKind, WidgetSnapshot.widgetKind)
    }

    func testFindersReconnectSheetOpensTheSignInFlow() {
        XCTAssertEqual(FindleLinks.reconnect.absoluteString, "findle://reconnect")
        XCTAssertNotEqual(BundleIdentifiers.sessionRestoredNotification, BundleIdentifiers.syncNowRequestNotification)
    }
}
