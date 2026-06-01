// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import XCTest

final class IndexStoreTests: XCTestCase {
    private func makeStore() throws -> IndexStore {
        try IndexStore(path: NSTemporaryDirectory() + "findle-idx-\(UUID().uuidString).db")
    }

    func testUpsertAndFullTextSearch() throws {
        let store = try makeStore()
        store.upsert(itemID: "a", courseID: 1, filename: "notes.pdf", content: "Las ecuaciones de Maxwell describen el campo electromagnético", contentVersion: "v1")

        let hits = store.search(query: "maxwell campo", courseID: nil, limit: 10)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.itemID, "a")
        XCTAssertTrue(hits.first!.snippet.lowercased().contains("maxwell"))
    }

    func testSearchIsDiacriticInsensitive() throws {
        let store = try makeStore()
        store.upsert(itemID: "a", courseID: 1, filename: "x", content: "Exámenes anteriores resueltos", contentVersion: "v1")
        XCTAssertEqual(store.search(query: "examenes", courseID: nil, limit: 10).count, 1)
    }

    func testPerCourseFilter() throws {
        let store = try makeStore()
        store.upsert(itemID: "a", courseID: 1, filename: "x", content: "shared keyword here", contentVersion: "v1")
        store.upsert(itemID: "b", courseID: 2, filename: "y", content: "shared keyword there", contentVersion: "v1")

        XCTAssertEqual(store.search(query: "keyword", courseID: 1, limit: 10).count, 1, "course filter restricts results")
        XCTAssertEqual(store.search(query: "keyword", courseID: nil, limit: 10).count, 2, "no filter returns both")
    }

    func testUpsertReplacesPreviousText() throws {
        let store = try makeStore()
        store.upsert(itemID: "a", courseID: 1, filename: "x", content: "alpha", contentVersion: "v1")
        store.upsert(itemID: "a", courseID: 1, filename: "x", content: "beta", contentVersion: "v2")
        XCTAssertEqual(store.search(query: "alpha", courseID: nil, limit: 10).count, 0)
        XCTAssertEqual(store.search(query: "beta", courseID: nil, limit: 10).count, 1)
    }

    func testCachedTextRespectsContentVersion() throws {
        let store = try makeStore()
        store.upsert(itemID: "a", courseID: 1, filename: "x", content: "hello world", contentVersion: "v1")
        XCTAssertEqual(store.cachedText(itemID: "a", contentVersion: "v1"), "hello world")
        XCTAssertNil(store.cachedText(itemID: "a", contentVersion: "v2"), "a version change misses the cache")
        XCTAssertNil(store.cachedText(itemID: "missing", contentVersion: "v1"))
    }

    func testEmbeddingsRoundTripAndLanguageFilter() throws {
        let store = try makeStore()
        XCTAssertFalse(store.hasEmbeddings(itemID: "a", contentVersion: "v1"))

        store.replaceEmbeddings(itemID: "a", courseID: 1, filename: "x", contentVersion: "v1", chunks: [
            .init(index: 0, text: "chunk one", language: "en", vector: [1, 0, 0]),
            .init(index: 1, text: "chunk two", language: "en", vector: [0, 1, 0]),
            .init(index: 2, text: "trozo", language: "es", vector: [0, 0, 1])
        ])
        XCTAssertTrue(store.hasEmbeddings(itemID: "a", contentVersion: "v1"))

        let english = store.fetchEmbeddings(language: "en", courseID: nil)
        XCTAssertEqual(english.count, 2)
        XCTAssertEqual(english.first { $0.chunkText == "chunk one" }?.vector, [1, 0, 0], "vector round-trips through the BLOB")

        XCTAssertEqual(store.fetchEmbeddings(language: "es", courseID: nil).count, 1)
        XCTAssertEqual(store.fetchEmbeddings(language: "en", courseID: 99).count, 0, "course filter applies")
    }
}
