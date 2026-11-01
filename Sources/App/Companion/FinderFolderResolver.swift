import Foundation
import SharedDomain

/// Finder can advertise AXDocument but return no value, including in File Provider
/// windows. Use actual content URLs as evidence; a matching title alone is not enough.
enum FinderFolderResolver {
    static func fileURL(_ value: Any?) -> URL? {
        let url: URL?
        if let value = value as? URL { url = value }
        else if let value = value as? String { url = URL(string: value) }
        else { url = nil }
        return url?.isFileURL == true ? url : nil
    }

    static func folderURL(windowTitle: String, itemURLs: [URL], rootURL: URL,
                          rootNames: Set<String>, columnView: Bool) -> URL? {
        let root = rootURL.standardizedFileURL
        var matches: [String: URL] = [:]
        for item in itemURLs where item.isFileURL {
            var candidates = [item.deletingLastPathComponent()]
            // An empty column still has its directory entry in the previous column.
            if columnView && item.hasDirectoryPath { candidates.append(item) }
            for candidate in candidates {
                let folder = candidate.standardizedFileURL
                guard folder.pathComponents.starts(with: root.pathComponents) else { continue }
                let isRoot = folder.pathComponents == root.pathComponents
                guard folder.lastPathComponent == windowTitle || (isRoot && rootNames.contains(windowTitle)) else { continue }
                matches[folder.path] = folder
            }
        }
        // Repeated directory names or mixed search results must not pick arbitrary context.
        return matches.count == 1 ? matches.values.first : nil
    }

    /// The course shown in the Finder folder `name` at the top of the Findle location.
    ///
    /// Two courses can sanitize to the same folder name. When only one of them is
    /// synced, that one owns the folder. Otherwise the name can't tell them apart,
    /// so no course is returned rather than a guess.
    static func course(folderName name: String, siteID: String?, in courses: [MoodleCourse]) -> MoodleCourse? {
        let named = courses.filter { $0.siteID == siteID && $0.effectiveFolderName == name }
        if named.count == 1 { return named[0] }
        let synced = named.filter(\.isSyncEnabled)
        return synced.count == 1 ? synced[0] : nil
    }
}
