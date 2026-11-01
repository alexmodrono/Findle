// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// Turns the HTML Moodle stores for labels and assignment briefs into readable
/// plain text for the README files Findle shows in Finder.
///
/// This runs during sync, off the main thread, so it doesn't use AppKit's HTML
/// import. It keeps paragraphs, line breaks, list items and links to web pages.
/// Links into Moodle's file store are dropped: their URLs need a token.
public enum MoodleText {
    public static func plainText(fromHTML html: String) -> String {
        var text = html
        text = replacing(#"<\s*(script|style)\b[^>]*>.*?<\s*/\s*\1\s*>"#, in: text, with: "", options: [.caseInsensitive, .dotMatchesLineSeparators])
        text = replacing(#"<a\b[^>]*href\s*=\s*["']([^"']*)["'][^>]*>(.*?)<\s*/\s*a\s*>"#, in: text, options: [.caseInsensitive, .dotMatchesLineSeparators]) { groups in
            let label = groups[2]
            let href = decodeEntities(groups[1])
            guard isShareableLink(href), stripTags(label).trimmingCharacters(in: .whitespacesAndNewlines) != href else { return label }
            return "\(label) (\(href))"
        }
        text = replacing(#"<\s*br\s*/?\s*>"#, in: text, with: "\n", options: .caseInsensitive)
        text = replacing(#"<\s*li\b[^>]*>"#, in: text, with: "\n- ", options: .caseInsensitive)
        text = replacing(#"<\s*/\s*(p|div|h[1-6]|ul|ol|tr|table|blockquote)\s*>"#, in: text, with: "\n\n", options: .caseInsensitive)
        text = stripTags(text)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: .newlines).map {
            $0.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        // Keep at most one blank line between paragraphs.
        var result: [String] = []
        for line in lines {
            if line.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(line)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }

    private static func isShareableLink(_ href: String) -> Bool {
        guard let components = URLComponents(string: href),
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else { return false }
        if components.path.contains("pluginfile.php") { return false }
        return !(components.queryItems ?? []).contains { $0.name.lowercased().contains("token") }
    }

    private static func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”"
    ]

    private static func decodeEntities(_ text: String) -> String {
        replacing(#"&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);"#, in: text) { groups in
            let entity = groups[1]
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? groups[0]
            }
            if entity.hasPrefix("#") {
                return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? groups[0]
            }
            return namedEntities[entity.lowercased()] ?? groups[0]
        }
    }

    private static func replacing(_ pattern: String, in text: String, with template: String,
                                  options: NSRegularExpression.Options = []) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func replacing(_ pattern: String, in text: String, options: NSRegularExpression.Options = [],
                                  transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let groups = (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            result += text[last..<range.lowerBound] + transform(groups)
            last = range.upperBound
        }
        return result + text[last...]
    }
}
