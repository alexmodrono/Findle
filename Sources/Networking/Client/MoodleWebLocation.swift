import Foundation
import SharedDomain

/// Moodle URL modules are local bookmarks, never authenticated downloads.
public enum MoodleWebLocation {
    public static func data(for item: LocalItem) throws -> Data? {
        guard !item.isLocal, !item.isDirectory,
              item.contentType == "com.apple.web-internet-location",
              item.id == "url-\(item.siteID)-\(item.courseID)-\(item.remoteID)" else { return nil }
        guard let url = item.remoteURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try data(for: url)
    }

    public static func data(for url: URL) throws -> Data {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return try PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
    }
}
