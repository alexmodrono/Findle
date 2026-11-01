import XCTest
import FileProvider
import SharedDomain

/// Evaluates the activation rules from the extension's Info.plist the way Finder
/// does: against `fileproviderItems`, the selected items.
final class FinderActionRuleTests: XCTestCase {
    private enum Action: String, CaseIterable {
        case syncNow = "sync-now"
        case openInMoodle = "open-in-moodle"
        case copyMoodleLink = "copy-moodle-link"
        case openCoursePage = "open-course-page"
        case keepDownloaded = "keep-downloaded"
        case removeDownload = "remove-download"
    }

    private var rules: [Action: NSPredicate] = [:]
    private var interactions: [(rule: NSPredicate, title: String, canContinue: Bool)] = []

    override func setUpWithError() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Info/FileProvider-Info.plist")
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
        )
        let actions = try XCTUnwrap(
            (plist["NSExtension"] as? [String: Any])?["NSExtensionFileProviderActions"] as? [[String: String]]
        )
        for entry in actions {
            let identifier = try XCTUnwrap(entry["NSExtensionFileProviderActionIdentifier"])
            let action = try XCTUnwrap(Action(rawValue: String(identifier.split(separator: ".").last ?? "")), identifier)
            rules[action] = NSPredicate(format: try XCTUnwrap(entry["NSExtensionFileProviderActionActivationRule"]))
        }
        XCTAssertEqual(Set(rules.keys), Set(Action.allCases), "Every action needs a rule")

        let entries = try XCTUnwrap((plist["NSExtension"] as? [String: Any])?["NSFileProviderUserInteractions"] as? [[String: Any]])
        for entry in entries {
            let alert = try XCTUnwrap(entry["Alert"] as? [String: Any])
            let options = alert["RecoveryOptions"] as? [String: Bool]
            XCTAssertNotNil(alert["LocalizedSubTitle"] as? String)
            interactions.append((NSPredicate(format: try XCTUnwrap(entry["ActivationRule"] as? String)),
                                 try XCTUnwrap(alert["LocalizedTitle"] as? String), options?["Continue"] ?? true))
        }
    }

    /// The alert Finder shows when the user tries `action` on `item`, if any.
    private func alert(for action: String, on item: NSObject) -> String? {
        let context: [String: Any] = ["action": action, "sourceItem": item, "sourceItemsCount": 1]
        let matches = interactions.filter { $0.rule.evaluate(with: context) }
        XCTAssertLessThanOrEqual(matches.count, 1, "\(action) matches several alerts")
        XCTAssertTrue(matches.allSatisfy { !$0.canContinue }, "The operation can't succeed, so the alert only explains")
        return matches.first?.title
    }

    private func visibleActions(for items: [NSObject]) -> Set<Action> {
        Set(rules.filter { $0.value.evaluate(with: ["fileproviderItems": items]) }.keys)
    }

    private func item(
        _ id: String, directory: Bool = false, kept: Bool = false, personal: Bool = false
    ) -> FileProviderItem {
        FileProviderItem(localItem: LocalItem(
            id: id, parentID: id.hasPrefix("course-") ? nil : "course-a-1", siteID: "a", courseID: 1, remoteID: 7,
            filename: id, isDirectory: directory, isPinned: kept, isLocal: personal
        ))
    }

    func testEachItemShowsOnlyTheActionsThatDoSomething() {
        let cases: [(String, NSObject, Set<Action>)] = [
            ("root", RootContainerItem(filename: "Findle"), [.syncNow, .openInMoodle, .copyMoodleLink]),
            ("course folder", item("course-a-1", directory: true),
             [.syncNow, .openInMoodle, .copyMoodleLink, .keepDownloaded]),
            ("section folder", item("section-a-1-2", directory: true),
             [.syncNow, .openInMoodle, .copyMoodleLink, .keepDownloaded]),
            ("module folder", item("folder-a-9", directory: true),
             [.syncNow, .openInMoodle, .copyMoodleLink, .openCoursePage, .keepDownloaded]),
            ("cloud-only file", item("file-a-1"),
             [.syncNow, .openInMoodle, .copyMoodleLink, .openCoursePage, .keepDownloaded]),
            ("kept file", item("file-a-2", kept: true),
             [.syncNow, .openInMoodle, .copyMoodleLink, .openCoursePage, .removeDownload]),
            ("kept folder", item("folder-a-3", directory: true, kept: true),
             [.syncNow, .openInMoodle, .copyMoodleLink, .openCoursePage, .removeDownload]),
            ("personal file", item("local-essay", personal: true), [.syncNow]),
            ("personal file in a kept folder", item("local-notes", kept: true, personal: true), [.syncNow]),
            ("stand-in for an unsynced course", item("course-a-2", directory: true, personal: true), [.syncNow])
        ]
        for (name, item, expected) in cases {
            XCTAssertEqual(visibleActions(for: [item]), expected, name)
        }
    }

    func testMultipleSelectionShowsActionsThatApplyToAnyItem() {
        XCTAssertEqual(visibleActions(for: [item("file-a-1"), item("file-a-2", kept: true)]),
                       [.syncNow, .keepDownloaded, .removeDownload],
                       "Moodle links and pages only open for a single item")
        XCTAssertEqual(visibleActions(for: [item("local-essay", personal: true), item("file-a-1")]),
                       [.syncNow, .keepDownloaded])
    }

    func testItemsThatHaveNotPublishedTheirStateKeepEveryAction() {
        XCTAssertEqual(visibleActions(for: [UnpublishedItem()]), Set(Action.allCases),
                       "Finder may still hold items from before Findle published their state")
    }

    func testChangingAMoodleItemExplainsWhyItCannotBeDone() {
        let moodleItems = [item("course-a-1", directory: true), item("section-a-1-2", directory: true),
                           item("folder-a-9", directory: true), item("file-a-1"), item("file-a-2", kept: true)]
        for moodleItem in moodleItems {
            let name = moodleItem.itemIdentifier.rawValue
            XCTAssertEqual(alert(for: "Trash", on: moodleItem), "Files from Moodle can’t be deleted", name)
            XCTAssertEqual(alert(for: "Delete", on: moodleItem), "Files from Moodle can’t be deleted", name)
            XCTAssertEqual(alert(for: "Rename", on: moodleItem), "Files from Moodle can’t be renamed", name)
            XCTAssertEqual(alert(for: "Move", on: moodleItem), "Files from Moodle can’t be moved", name)
            XCTAssertEqual(alert(for: "MoveOut", on: moodleItem), "Files from Moodle can’t be moved", name)
            XCTAssertNil(alert(for: "Copy", on: moodleItem), "Copying a Moodle file is how to keep your own")
            XCTAssertNil(alert(for: "CopyOut", on: moodleItem))
        }
    }

    func testPersonalFilesAndTheRootChangeWithoutAlerts() {
        let others: [NSObject] = [item("local-essay", personal: true), item("local-notes", directory: true, personal: true),
                                  RootContainerItem(filename: "Findle"), UnpublishedItem()]
        for other in others {
            for action in ["Trash", "Delete", "Rename", "Move", "MoveOut", "Copy", "CopyOut", "MoveIn", "CopyIn", "Create"] {
                XCTAssertNil(alert(for: action, on: other), "\(action) on \(other)")
            }
        }
    }

    func testPublishedStateReachesTheSystemAsNewMetadata() {
        let published = FileProviderItem(localItem: LocalItem(id: "file-a-1", siteID: "a", courseID: 1, remoteID: 7,
                                                              filename: "a.pdf", modificationDate: Date(timeIntervalSince1970: 5)))
        let metadata = String(decoding: published.itemVersion.metadataVersion, as: UTF8.self)
        XCTAssertTrue(metadata.hasSuffix("|" + FinderActionState.revision), metadata)
        let root = String(decoding: RootContainerItem(filename: "Findle").itemVersion.metadataVersion, as: UTF8.self)
        XCTAssertTrue(root.hasSuffix("|" + FinderActionState.revision), root)
    }
}

/// An item as Finder may have cached it before Findle published `userInfo`.
private final class UnpublishedItem: NSObject {
    @objc var userInfo: [AnyHashable: Any]? { nil }
}
