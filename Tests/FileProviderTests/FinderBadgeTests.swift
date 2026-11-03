import FileProvider
import XCTest
@testable import SharedDomain

/// The badges items carry, checked against what the extension's Info.plist declares.
final class FinderBadgeTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func infoPlist() throws -> [String: Any] {
        let url = repository.appendingPathComponent("Resources/Info/FileProvider-Info.plist")
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    /// The plist names identifiers with the build setting the code resolves at run time.
    private func declared(_ identifier: NSFileProviderItemDecorationIdentifier) -> String {
        identifier.rawValue.replacingOccurrences(of: BundleIdentifiers.prefix, with: "$(FINDLE_BUNDLE_PREFIX)")
    }

    private func item(_ badges: ItemBadges) -> LocalItem {
        LocalItem(id: "file", parentID: "week", siteID: "site", courseID: 1, remoteID: 1, filename: "slides.pdf",
                  contentVersion: "1", badges: badges)
    }

    func testEveryBadgeIsDeclaredWithAnImageFinderCanDraw() throws {
        let plist = try infoPlist()
        let decorations = try XCTUnwrap((plist["NSExtension"] as? [String: Any])?["NSFileProviderDecorations"] as? [[String: String]])
        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])

        for badge in ItemBadges.priority {
            let identifier = try XCTUnwrap(FinderBadges.identifier(for: badge))
            let decoration = try XCTUnwrap(decorations.first { $0["Identifier"] == declared(identifier) },
                                           "\(identifier.rawValue) is not declared")
            XCTAssertEqual(decoration["Category"], "Badge")
            XCTAssertFalse(decoration["Label", default: ""].isEmpty)

            let imageType = try XCTUnwrap(decoration["BadgeImageType"])
            if imageType.hasPrefix("com.apple.icon-decoration.badge.") { continue }
            let type = try XCTUnwrap(exported.first { $0["UTTypeIdentifier"] as? String == imageType },
                                     "\(imageType) is not exported")
            XCTAssertTrue((type["UTTypeConformsTo"] as? [String] ?? []).contains("com.apple.icon-decoration.badge"))
            let icon = try XCTUnwrap(type["UTTypeIconFile"] as? String)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: repository.appendingPathComponent("Resources/Badges/\(icon).icns").path), "\(icon).icns is missing")
        }
    }

    func testTheMostPressingBadgeComesFirst() {
        XCTAssertNil(FinderBadges.decorations(for: item([])))
        XCTAssertEqual(FinderBadges.decorations(for: item([.kept, .new])), [FinderBadges.new, FinderBadges.kept])
        XCTAssertEqual(FinderBadges.decorations(for: item([.kept, .dueSoon]))?.first, FinderBadges.dueSoon)
    }

    func testABadgeChangeIsNewMetadataForFinder() {
        let plain = FileProviderItem(localItem: item([])).itemVersion
        let new = FileProviderItem(localItem: item(.new)).itemVersion
        XCTAssertEqual(plain.contentVersion, new.contentVersion, "A badge never asks for a new download")
        XCTAssertNotEqual(plain.metadataVersion, new.metadataVersion)
        XCTAssertNotEqual(new.metadataVersion, FileProviderItem(localItem: item([.new, .kept])).itemVersion.metadataVersion)
    }
}
