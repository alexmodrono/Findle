// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest

final class ExtractionTests: XCTestCase {
    private func tempFile(_ suffix: String, _ content: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(UUID().uuidString).\(suffix)")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testExtractsPlainText() throws {
        let url = try tempFile("txt", "Hello, world")
        guard case .text(let text) = Catalog.extractText(from: url, filename: "notes.txt") else {
            return XCTFail("expected .text")
        }
        XCTAssertEqual(text, "Hello, world")
    }

    func testStripsHTML() throws {
        let url = try tempFile("html", "<h1>Title</h1><p>Some <b>body</b></p>")
        guard case .text(let text) = Catalog.extractText(from: url, filename: "page.html") else {
            return XCTFail("expected .text")
        }
        XCTAssertFalse(text.contains("<"))
        XCTAssertTrue(text.contains("Title"))
        XCTAssertTrue(text.contains("body"))
    }

    func testUnsupportedType() {
        let result = Catalog.extractText(from: URL(fileURLWithPath: "/tmp/x.bin"), filename: "x.bin")
        guard case .unsupported = result else { return XCTFail("expected .unsupported") }
    }

    func testUnreadableFile() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory() + "does-not-exist-\(UUID().uuidString).txt")
        guard case .unreadable = Catalog.extractText(from: missing, filename: "missing.txt") else {
            return XCTFail("a read failure must be .unreadable, not cached as empty")
        }
    }

    func testBestChildMatchDisambiguatesPrefixSiblings() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bcm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["Cálculo", "Cálculo II"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(name), withIntermediateDirectories: true)
        }

        // DB stores "X [CODE]" but disk has "X" — longest prefix wins, so the
        // shorter name doesn't swallow its longer sibling and vice versa.
        XCTAssertEqual(Catalog.bestChildMatch(in: dir, name: "Cálculo [DMA-101]")?.lastPathComponent, "Cálculo")
        XCTAssertEqual(Catalog.bestChildMatch(in: dir, name: "Cálculo II [DMA-201]")?.lastPathComponent, "Cálculo II")
        // Case- and diacritic-insensitive exact match.
        XCTAssertEqual(Catalog.bestChildMatch(in: dir, name: "calculo ii")?.lastPathComponent, "Cálculo II")
        // No match.
        XCTAssertNil(Catalog.bestChildMatch(in: dir, name: "Física"))
    }
}
