// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import NaturalLanguage

/// On-device text embedding via Apple's NaturalLanguage sentence models.
///
/// Zero footprint: the sentence-embedding models ship with macOS, so there's
/// nothing to download. Recall is weaker than a dedicated transformer, but it
/// validates semantic search for free (design decision D5); a lazy-downloaded
/// model is the documented upgrade path.
///
/// Embeddings are language-specific and NOT comparable across languages, so the
/// language actually used is recorded with each chunk and a query is only
/// compared against chunks embedded in the same language.
final class Embedder: @unchecked Sendable {
    private var models: [NLLanguage: NLEmbedding?] = [:]
    private let lock = NSLock()

    /// Dominant language of `text`, defaulting to English when undetectable.
    static func detectLanguage(_ text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? .english
    }

    /// Embed `text`, returning the vector and the language actually used (which
    /// may differ from `language` if that model is unavailable). Returns nil if
    /// no sentence model is available at all.
    func embed(_ text: String, language: NLLanguage) -> (vector: [Float], language: NLLanguage)? {
        for candidate in [language, .english, .spanish] {
            guard let model = model(for: candidate) else { continue }
            if let vector = model.vector(for: text) {
                return (vector.map(Float.init), candidate)
            }
        }
        return nil
    }

    private func model(for language: NLLanguage) -> NLEmbedding? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = models[language] {
            return cached
        }
        let model = NLEmbedding.sentenceEmbedding(for: language)
        models[language] = model
        return model
    }

    // MARK: - Math

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denominator = normA.squareRoot() * normB.squareRoot()
        return denominator > 0 ? dot / denominator : 0
    }

    // MARK: - Chunking

    /// Split `text` into overlapping passages, breaking on whitespace near the
    /// limit so words aren't cut mid-token.
    static func chunks(of text: String, maxChars: Int = 1200, overlap: Int = 150) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxChars else { return trimmed.isEmpty ? [] : [trimmed] }

        let chars = Array(trimmed)
        var result: [String] = []
        var start = 0

        while start < chars.count {
            var end = min(start + maxChars, chars.count)
            if end < chars.count {
                var back = end
                while back > start + maxChars - overlap, back > start, !chars[back - 1].isWhitespace {
                    back -= 1
                }
                if back > start { end = back }
            }

            let chunk = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { result.append(chunk) }

            if end >= chars.count { break }
            start = max(end - overlap, start + 1)
        }

        return result
    }
}
