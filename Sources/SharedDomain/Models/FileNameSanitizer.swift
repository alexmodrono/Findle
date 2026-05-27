// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// Sanitizes strings for use as file and folder names in Finder.
public enum FileNameSanitizer {
    /// Characters forbidden in macOS filenames.
    /// Forward slash and NUL are kernel-level reserved on HFS/APFS; colon is
    /// remapped to slash by Finder and breaks SMB/iCloud round-trips; backslash
    /// is permitted by the filesystem but breaks plenty of clients; control
    /// characters survive as garbage in Finder if not stripped.
    private static let forbiddenCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: "/:\\\0")
        set.formUnion(.controlCharacters)
        return set
    }()

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

        // Collapse multiple dashes (single pass — avoids O(n²) on adversarial input).
        sanitized = collapseDashes(sanitized)

        // Remove leading dots (hidden files in UNIX)
        while sanitized.hasPrefix(".") {
            sanitized = String(sanitized.dropFirst())
        }

        // Remove leading/trailing dashes
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        // Reserved single-/double-dot names map to Untitled.
        if sanitized.isEmpty || sanitized == "." || sanitized == ".." {
            sanitized = "Untitled"
        }

        // Truncate if too long, preserving scalar boundaries so the result is
        // always valid UTF-8 (slicing utf8 by byte count can land mid-scalar).
        if sanitized.utf8.count > maxLength {
            if preserveExtension,
               let dotIndex = sanitized.lastIndex(of: "."),
               looksLikeExtension(sanitized[dotIndex...]) {
                let ext = String(sanitized[dotIndex...])
                let stem = String(sanitized[..<dotIndex])
                let maxStem = max(0, maxLength - ext.utf8.count)
                sanitized = truncateByScalars(stem, maxBytes: maxStem) + ext
            } else {
                sanitized = truncateByScalars(sanitized, maxBytes: maxLength)
            }
        }

        return sanitized
    }

    /// Walk the scalar sequence accumulating UTF-8 bytes, stopping before
    /// exceeding `maxBytes`. Always returns a valid UTF-8 string.
    private static func truncateByScalars(_ s: String, maxBytes: Int) -> String {
        var bytes = 0
        var result = ""
        result.reserveCapacity(min(maxBytes, s.utf8.count))
        for scalar in s.unicodeScalars {
            let scalarBytes = UTF8.width(scalar)
            if bytes + scalarBytes > maxBytes { break }
            bytes += scalarBytes
            result.unicodeScalars.append(scalar)
        }
        return result
    }

    private static func collapseDashes(_ s: String) -> String {
        var result = ""
        result.reserveCapacity(s.count)
        var lastWasDash = false
        for ch in s {
            if ch == "-" {
                if !lastWasDash { result.append(ch) }
                lastWasDash = true
            } else {
                result.append(ch)
                lastWasDash = false
            }
        }
        return result
    }

    /// Heuristic: only treat `.xyz` as an extension when xyz looks like a
    /// real extension (1-6 alphanumeric chars). Otherwise a name like
    /// "My.Course.Name" would lose part of its stem during truncation.
    private static func looksLikeExtension(_ suffix: Substring) -> Bool {
        guard suffix.first == "." else { return false }
        let ext = suffix.dropFirst()
        guard (1...6).contains(ext.count) else { return false }
        return ext.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
