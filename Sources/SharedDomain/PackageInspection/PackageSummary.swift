// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// What Quick Look shows for one of Moodle's interactive packages: its title,
/// what kind of activity it is, and a first image when the package has one.
public struct PackageSummary: Equatable {
    public enum Kind: Equatable { case h5p, scorm }

    public let kind: Kind
    public let title: String
    /// "Interactive Video", "SCORM 2004", …
    public let activityType: String
    public let details: [String]
    public let image: (data: Data, mimeType: String)?

    public static func == (lhs: PackageSummary, rhs: PackageSummary) -> Bool {
        lhs.kind == rhs.kind && lhs.title == rhs.title && lhs.activityType == rhs.activityType
            && lhs.details == rhs.details && lhs.image?.data == rhs.image?.data && lhs.image?.mimeType == rhs.image?.mimeType
    }

    public enum Failure: Error { case notAPackage }

    /// Reads an H5P or SCORM package. Anything else throws, so Quick Look
    /// falls back to its default preview.
    public static func read(_ data: Data) throws -> PackageSummary {
        let zip = try ZipReader(data: data)
        if let manifest = zip.entry("h5p.json") {
            return try h5p(zip, manifest: manifest)
        }
        if let manifest = zip.entry("imsmanifest.xml") {
            return try scorm(zip, manifest: manifest)
        }
        throw Failure.notAPackage
    }

    private static func h5p(_ zip: ZipReader, manifest: ZipReader.Entry) throws -> PackageSummary {
        guard let json = try JSONSerialization.jsonObject(with: zip.contents(of: manifest)) as? [String: Any] else {
            throw Failure.notAPackage
        }
        let library = json["mainLibrary"] as? String ?? ""
        var details: [String] = []
        if let language = json["language"] as? String, !language.isEmpty, language != "und" { details.append("Language: \(language)") }
        if let authors = json["authors"] as? [[String: Any]] {
            let names = authors.compactMap { $0["name"] as? String }.filter { !$0.isEmpty }
            if !names.isEmpty { details.append("By \(names.joined(separator: ", "))") }
        }
        if let license = json["license"] as? String, !license.isEmpty, license != "U" { details.append("License: \(license)") }
        let image = zip.entries
            .filter { $0.path.hasPrefix("content/images/") && imageType(of: $0.path) != nil }
            .min { $0.path < $1.path }
            .flatMap { entry in (try? zip.contents(of: entry)).map { ($0, imageType(of: entry.path)!) } }
        return PackageSummary(kind: .h5p, title: (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "H5P activity",
                              activityType: humanize(library), details: details, image: image)
    }

    private static func scorm(_ zip: ZipReader, manifest: ZipReader.Entry) throws -> PackageSummary {
        let document = try XMLDocument(data: zip.contents(of: manifest))
        func values(_ xpath: String) -> [String] {
            ((try? document.nodes(forXPath: xpath)) ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        let title = values("//*[local-name()='organization']/*[local-name()='title']").first
            ?? values("//*[local-name()='title']").first ?? "SCORM package"
        let version = values("//*[local-name()='schemaversion']").first ?? ""
        let type = version.contains("2004") || version.lowercased().contains("cam") ? "SCORM 2004"
            : version.contains("1.2") ? "SCORM 1.2" : "SCORM"
        let scos = values("//*[local-name()='item']/*[local-name()='title']").count
        let details = scos > 1 ? ["\(scos) parts"] : []
        return PackageSummary(kind: .scorm, title: title, activityType: type, details: details, image: nil)
    }

    /// "H5P.InteractiveVideo" → "Interactive Video".
    static func humanize(_ library: String) -> String {
        let name = library.split(separator: ".").last.map(String.init) ?? library
        guard !name.isEmpty else { return "Interactive content" }
        var words = ""
        for (index, character) in name.enumerated() {
            if index > 0, character.isUppercase,
               let previous = words.last, previous.isLowercase { words.append(" ") }
            words.append(character)
        }
        return words
    }

    private static func imageType(of path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: nil
        }
    }

    /// A self-contained page for Quick Look.
    public var html: String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let picture = image.map { #"<img src="data:\#($0.mimeType);base64,\#($0.data.base64EncodedString())" alt="">"# } ?? ""
        let rows = details.map { "<li>\(escape($0))</li>" }.joined()
        return """
            <!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><style>
            body{font:15px -apple-system,sans-serif;margin:32px;color:CanvasText;background:Canvas}
            .kind{color:GrayText;font-size:13px;text-transform:uppercase;letter-spacing:.04em}
            h1{font-size:24px;margin:6px 0 14px}ul{padding-left:18px;color:GrayText}
            img{max-width:100%;max-height:360px;border-radius:8px;margin-top:12px}
            </style></head><body><div class="kind">\(escape(kind == .h5p ? "H5P · \(activityType)" : activityType))</div>
            <h1>\(escape(title))</h1><ul>\(rows)</ul>\(picture)</body></html>
            """
    }
}
