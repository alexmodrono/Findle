// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// Sanitizes strings for use as file and folder names in Finder.
public enum FileNameSanitizer {
    /// Characters forbidden in macOS filenames.
    private static let forbiddenCharacters = CharacterSet(charactersIn: "/:\0")

    /// Maximum filename length (HFS+/APFS limit is 255 UTF-8 bytes).
    private static let maxLength = 200

    /// Sanitize a string for use as a filename.
    /// - Parameters:
    ///   - name: The raw name to sanitize.
    ///   - preserveExtension: If true, preserves the file extension during truncation.
    /// - Returns: A safe, human-friendly filename.
    public static func sanitize(_ name: String, preserveExtension: Bool = false) -> String {
        var sanitized = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Replace forbidden characters with dashes
        sanitized = sanitized.unicodeScalars
            .map { forbiddenCharacters.contains($0) ? "-" : String($0) }
            .joined()

        // Collapse multiple dashes
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }

        // Remove leading dots (hidden files in UNIX)
        while sanitized.hasPrefix(".") {
            sanitized = String(sanitized.dropFirst())
        }

        // Remove leading/trailing dashes
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Fallback for empty names
        if sanitized.isEmpty {
            sanitized = "Untitled"
        }

        // Truncate if too long
        if sanitized.utf8.count > maxLength {
            if preserveExtension, let dotIndex = sanitized.lastIndex(of: ".") {
                let ext = String(sanitized[dotIndex...])
                let stem = String(sanitized[..<dotIndex])
                let maxStem = maxLength - ext.utf8.count
                let truncated = String(stem.utf8.prefix(maxStem)) ?? stem.prefix(maxStem / 4).description
                sanitized = truncated + ext
            } else {
                sanitized = String(sanitized.utf8.prefix(maxLength)) ?? String(sanitized.prefix(maxLength / 4))
            }
        }

        return sanitized
    }
}
