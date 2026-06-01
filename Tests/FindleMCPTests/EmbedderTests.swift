// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest

final class EmbedderTests: XCTestCase {
    func testChunksOfShortText() {
        XCTAssertEqual(Embedder.chunks(of: "short text"), ["short text"])
        XCTAssertEqual(Embedder.chunks(of: "   \n  "), [])
    }

    func testChunksOfLongTextRespectBoundsAndCoverEverything() {
        let text = String(repeating: "palabra ", count: 1000) // ~8000 chars
        let chunks = Embedder.chunks(of: text, maxChars: 1000, overlap: 100)

        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 1000, "no chunk exceeds maxChars")
        }
        // The last word must appear somewhere (nothing dropped off the end).
        XCTAssertTrue(chunks.contains { $0.contains("palabra") })
    }

    func testCosineSimilarity() {
        XCTAssertEqual(Embedder.cosineSimilarity([1, 0, 0], [1, 0, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(Embedder.cosineSimilarity([1, 0, 0], [0, 1, 0]), 0, accuracy: 0.0001)
        XCTAssertEqual(Embedder.cosineSimilarity([1, 0], [-1, 0]), -1, accuracy: 0.0001)
        XCTAssertEqual(Embedder.cosineSimilarity([2, 2], [1, 1]), 1, accuracy: 0.0001, "scale-invariant")
        XCTAssertEqual(Embedder.cosineSimilarity([], []), 0, "empty is safe")
        XCTAssertEqual(Embedder.cosineSimilarity([1, 2], [1]), 0, "mismatched lengths are safe")
    }
}
