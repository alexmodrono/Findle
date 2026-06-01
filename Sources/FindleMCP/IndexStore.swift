// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// An MCP-owned, writable full-text index over extracted file text. This is the
/// server's *own* database (under `~/Library/Caches/FindleMCP`), kept entirely
/// separate from Findle's shared DB — so the "app is the single writer" rule on
/// the shared database is never violated. It doubles as the `item_text` cache:
/// once a file's text is extracted it's stored here, keyed by content version,
/// so repeat reads don't re-open the PDF.
final class IndexStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "es.amodrono.foodle.mcp.index")

    struct Hit {
        let itemID: String
        let courseID: Int
        let filename: String
        let snippet: String
    }

    /// Opens the index database. `path` is injectable for tests; production uses
    /// the default cache location.
    init(path: String? = nil) throws {
        let resolvedPath: String
        if let path {
            resolvedPath = path
        } else {
            let dir = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches/FindleMCP", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            resolvedPath = dir.appendingPathComponent("index.db").path
        }

        guard sqlite3_open_v2(resolvedPath, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw Failure.open
        }
        sqlite3_busy_timeout(db, 3000)

        // FTS5 with unicode61 + diacritic folding so accented Spanish content is
        // searchable without accents ("examen" finds "exámenes").
        try exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS item_text USING fts5(
                item_id UNINDEXED,
                course_id UNINDEXED,
                filename,
                content,
                content_version UNINDEXED,
                tokenize = 'unicode61 remove_diacritics 2'
            );
        """)

        // Per-chunk on-device embeddings for semantic search. `vector` is a raw
        // little-endian Float32 array; `language` records the model used so a
        // query is only compared against chunks in the same embedding space.
        try exec("""
            CREATE TABLE IF NOT EXISTS embeddings (
                item_id TEXT NOT NULL,
                course_id INTEGER NOT NULL,
                filename TEXT NOT NULL,
                chunk_index INTEGER NOT NULL,
                chunk_text TEXT NOT NULL,
                language TEXT NOT NULL,
                vector BLOB NOT NULL,
                content_version TEXT NOT NULL,
                PRIMARY KEY (item_id, chunk_index)
            );
        """)
    }

    struct EmbeddingChunk {
        let index: Int
        let text: String
        let language: String
        let vector: [Float]
    }

    struct EmbeddingHit {
        let itemID: String
        let courseID: Int
        let filename: String
        let chunkText: String
        let vector: [Float]
    }

    /// Whether `itemID` already has embeddings stored at the given content version.
    func hasEmbeddings(itemID: String, contentVersion: String) -> Bool {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM embeddings WHERE item_id = ? AND content_version = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else { return false }
            sqlite3_bind_text(stmt, 1, itemID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, contentVersion, -1, SQLITE_TRANSIENT)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    /// Replace all embeddings for `itemID` with a fresh set of chunks.
    func replaceEmbeddings(itemID: String, courseID: Int, filename: String, contentVersion: String, chunks: [EmbeddingChunk]) {
        queue.sync {
            _ = run("DELETE FROM embeddings WHERE item_id = ?") { sqlite3_bind_text($0, 1, itemID, -1, SQLITE_TRANSIENT) }
            for chunk in chunks {
                let blob = chunk.vector.withUnsafeBufferPointer { Data(buffer: $0) }
                _ = run("INSERT INTO embeddings (item_id, course_id, filename, chunk_index, chunk_text, language, vector, content_version) VALUES (?, ?, ?, ?, ?, ?, ?, ?)") { stmt in
                    sqlite3_bind_text(stmt, 1, itemID, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 2, Int64(courseID))
                    sqlite3_bind_text(stmt, 3, filename, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_int64(stmt, 4, Int64(chunk.index))
                    sqlite3_bind_text(stmt, 5, chunk.text, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_text(stmt, 6, chunk.language, -1, SQLITE_TRANSIENT)
                    blob.withUnsafeBytes { raw in
                        _ = sqlite3_bind_blob(stmt, 7, raw.baseAddress, Int32(raw.count), SQLITE_TRANSIENT)
                    }
                    sqlite3_bind_text(stmt, 8, contentVersion, -1, SQLITE_TRANSIENT)
                }
            }
        }
    }

    /// All embedded chunks in a given language (optionally scoped to a course),
    /// for brute-force cosine ranking.
    func fetchEmbeddings(language: String, courseID: Int?) -> [EmbeddingHit] {
        queue.sync {
            var sql = "SELECT item_id, course_id, filename, chunk_text, vector FROM embeddings WHERE language = ?"
            if courseID != nil { sql += " AND course_id = ?" }

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            sqlite3_bind_text(stmt, 1, language, -1, SQLITE_TRANSIENT)
            if let courseID { sqlite3_bind_int64(stmt, 2, Int64(courseID)) }

            var hits: [EmbeddingHit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let bytes = sqlite3_column_bytes(stmt, 4)
                var vector: [Float] = []
                if let blob = sqlite3_column_blob(stmt, 4), bytes > 0 {
                    let count = Int(bytes) / MemoryLayout<Float>.stride
                    vector = Array(UnsafeBufferPointer(start: blob.assumingMemoryBound(to: Float.self), count: count))
                }
                hits.append(EmbeddingHit(
                    itemID: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
                    courseID: Int(sqlite3_column_int64(stmt, 1)),
                    filename: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                    chunkText: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "",
                    vector: vector
                ))
            }
            return hits
        }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    /// Cached full text for an item at a given content version, if present.
    func cachedText(itemID: String, contentVersion: String) -> String? {
        queue.sync {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT content FROM item_text WHERE item_id = ? AND content_version = ? LIMIT 1", -1, &stmt, nil) == SQLITE_OK else {
                return nil
            }
            sqlite3_bind_text(stmt, 1, itemID, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, contentVersion, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        }
    }

    /// Replace any existing text for `itemID` with the freshly extracted text.
    func upsert(itemID: String, courseID: Int, filename: String, content: String, contentVersion: String) {
        queue.sync {
            _ = run("DELETE FROM item_text WHERE item_id = ?") { sqlite3_bind_text($0, 1, itemID, -1, SQLITE_TRANSIENT) }
            _ = run("INSERT INTO item_text (item_id, course_id, filename, content, content_version) VALUES (?, ?, ?, ?, ?)") { stmt in
                sqlite3_bind_text(stmt, 1, itemID, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(stmt, 2, Int64(courseID))
                sqlite3_bind_text(stmt, 3, filename, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 4, content, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 5, contentVersion, -1, SQLITE_TRANSIENT)
            }
        }
    }

    func search(query: String, courseID: Int?, limit: Int) -> [Hit] {
        let match = Self.ftsQuery(from: query)
        guard !match.isEmpty else { return [] }

        return queue.sync {
            var sql = "SELECT item_id, course_id, filename, snippet(item_text, 3, '«', '»', '…', 14) FROM item_text WHERE item_text MATCH ?"
            // CAST: course_id is an FTS5 UNINDEXED column; its stored affinity is
            // unreliable, so compare as an integer to keep scoped search correct.
            if courseID != nil { sql += " AND CAST(course_id AS INTEGER) = ?" }
            sql += " ORDER BY rank LIMIT ?"

            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }

            var idx: Int32 = 1
            sqlite3_bind_text(stmt, idx, match, -1, SQLITE_TRANSIENT); idx += 1
            if let courseID { sqlite3_bind_int64(stmt, idx, Int64(courseID)); idx += 1 }
            sqlite3_bind_int(stmt, idx, Int32(max(1, limit)))

            var hits: [Hit] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                hits.append(Hit(
                    itemID: sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "",
                    courseID: Int(sqlite3_column_int64(stmt, 1)),
                    filename: sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "",
                    snippet: sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                ))
            }
            return hits
        }
    }

    // MARK: - Helpers

    /// Turn arbitrary user text into a safe FTS5 MATCH expression: each
    /// whitespace token becomes a quoted string, AND-ed together. Quoting avoids
    /// FTS5 syntax errors on punctuation in the query.
    private static func ftsQuery(from query: String) -> String {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
            .joined(separator: " ")
    }

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.exec(String(cString: sqlite3_errmsg(db)))
        }
    }

    @discardableResult
    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        bind(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    enum Failure: Error {
        case open
        case exec(String)
    }
}
