// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest
@testable import FoodleNetworking
@testable import SharedDomain

final class MoodleSSOLaunchURLBuilderTests: XCTestCase {

    private let passport = "testpassport123"
    private let callbackScheme = "findle"

    private func makeSite(
        baseURL: String = "https://moodle.example.edu",
        launchURL: String? = nil
    ) -> MoodleSite {
        MoodleSite(
            displayName: "Test Site",
            baseURL: URL(string: baseURL)!,
            capabilities: SiteCapabilities(
                supportsWebServices: true,
                supportsMobileAPI: true,
                supportsFileDownload: true,
                loginType: .browser,
                launchURL: launchURL
            )
        )
    }

    // MARK: - 1. Base URL only, no launchurl

    func testFallbackWhenNoLaunchURL() throws {
        let site = makeSite()
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .fallback)

        let components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!
        XCTAssertTrue(result.url.path.hasSuffix("/admin/tool/mobile/launch.php"))
        assertRequiredQueryItems(components)
    }

    // MARK: - 2. Absolute launchurl with no query

    func testAbsoluteLaunchURLNoQuery() throws {
        let site = makeSite(launchURL: "https://auth.example.edu/mobile/launch")
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .advertised)
        XCTAssertEqual(result.url.host, "auth.example.edu")
        XCTAssertEqual(result.url.path, "/mobile/launch")

        let components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!
        assertRequiredQueryItems(components)
    }

    // MARK: - 3. Absolute launchurl with existing query items

    func testAbsoluteLaunchURLWithExistingQueryItems() throws {
        let site = makeSite(launchURL: "https://moodle.example.edu/admin/tool/mobile/launch.php?lang=en&authCAS=CAS")
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .advertised)

        let components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!
        assertRequiredQueryItems(components)

        // Unrelated items must be preserved.
        XCTAssertEqual(queryValue("lang", in: components), "en")
        XCTAssertEqual(queryValue("authCAS", in: components), "CAS")
    }

    // MARK: - 4. Relative launchurl

    func testRelativeLaunchURL() throws {
        let site = makeSite(
            baseURL: "https://example.edu/moodle",
            launchURL: "admin/tool/mobile/launch.php"
        )
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .advertised)
        XCTAssertEqual(result.url.host, "example.edu")
        // The path should be under /moodle, not at the domain root.
        XCTAssertTrue(result.url.path.contains("admin/tool/mobile/launch.php"))

        let components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!
        assertRequiredQueryItems(components)
    }

    func testRelativeLaunchURLWithLeadingSlash() throws {
        let site = makeSite(launchURL: "/admin/tool/mobile/launch.php")
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .advertised)

        let components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!
        assertRequiredQueryItems(components)
    }

    // MARK: - 5. Malformed launchurl

    func testMalformedLaunchURLFallsBackGracefully() throws {
        let site = makeSite(launchURL: "://totally broken url{}")
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .fallback)
        XCTAssertTrue(result.url.path.hasSuffix("/admin/tool/mobile/launch.php"))

        let components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!
        assertRequiredQueryItems(components)
    }

    // MARK: - 6. Trailing slash / no trailing slash base URL

    func testBaseURLWithTrailingSlash() throws {
        let site = makeSite(baseURL: "https://moodle.example.edu/")
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .fallback)
        // Should not produce double slashes.
        XCTAssertFalse(result.url.absoluteString.contains("//admin"))

        let components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!
        assertRequiredQueryItems(components)
    }

    func testBaseURLWithoutTrailingSlash() throws {
        let site = makeSite(baseURL: "https://moodle.example.edu")
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .fallback)

        let components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!
        assertRequiredQueryItems(components)
    }

    // MARK: - 7. Preexisting required keys are replaced

    func testPreexistingRequiredKeysAreReplaced() throws {
        let site = makeSite(launchURL: "https://moodle.example.edu/launch.php?service=old&passport=stale&urlscheme=other&lang=en")
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .advertised)

        let components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!
        assertRequiredQueryItems(components)

        // Unrelated items preserved.
        XCTAssertEqual(queryValue("lang", in: components), "en")

        // Must not have duplicates of the required keys.
        let serviceCount = components.queryItems?.filter { $0.name == "service" }.count ?? 0
        XCTAssertEqual(serviceCount, 1)
    }

    // MARK: - 8. Unrelated query items preserved

    func testUnrelatedQueryItemsPreserved() throws {
        let site = makeSite(launchURL: "https://moodle.example.edu/launch.php?lang=es&theme=dark&custom=value")
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        let components = URLComponents(url: result.url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(queryValue("lang", in: components), "es")
        XCTAssertEqual(queryValue("theme", in: components), "dark")
        XCTAssertEqual(queryValue("custom", in: components), "value")
        assertRequiredQueryItems(components)
    }

    // MARK: - 9. Empty or whitespace-only launchurl

    func testEmptyLaunchURL() throws {
        let site = makeSite(launchURL: "")
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .fallback)
    }

    func testWhitespaceOnlyLaunchURL() throws {
        let site = makeSite(launchURL: "   \t  ")
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .fallback)
    }

    func testNilLaunchURL() throws {
        let site = makeSite(launchURL: nil)
        let result = try MoodleSSOLaunchURLBuilder.build(for: site, passport: passport, callbackScheme: callbackScheme)

        XCTAssertEqual(result.source, .fallback)
    }

    // MARK: - Helpers

    private func assertRequiredQueryItems(_ components: URLComponents, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(queryValue("service", in: components), "moodle_mobile_app", file: file, line: line)
        XCTAssertEqual(queryValue("passport", in: components), passport, file: file, line: line)
        XCTAssertEqual(queryValue("urlscheme", in: components), callbackScheme, file: file, line: line)

        // Each required key must appear exactly once.
        for key in ["service", "passport", "urlscheme"] {
            let count = components.queryItems?.filter { $0.name == key }.count ?? 0
            XCTAssertEqual(count, 1, "Expected exactly 1 '\(key)' query item, found \(count)", file: file, line: line)
        }
    }

    private func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first(where: { $0.name == name })?.value
    }
}
