import Foundation

/// Builds user-facing Moodle web URLs for items and courses.
public enum MoodleURLBuilder {

    /// Returns the web URL for a specific item on a Moodle site.
    ///
    /// For files and folders backed by a module, this points to the module view page.
    /// For course-level and section-level directories, this points to the course page.
    public static func webURL(
        baseURL: URL,
        itemID: String,
        courseID: Int,
        remoteID: Int,
        isDirectory: Bool
    ) -> URL {
        // Course root items link to the course page.
        if itemID.hasPrefix("course-") {
            return courseURL(baseURL: baseURL, courseID: courseID)
        }

        // Section items link to the course page with a section anchor.
        if itemID.hasPrefix("section-") {
            return courseURL(baseURL: baseURL, courseID: courseID)
        }

        // Folder modules link to the folder view page.
        if isDirectory {
            return moduleURL(baseURL: baseURL, moduleName: "folder", cmid: remoteID)
        }

        // URL resources link to their module page directly.
        if itemID.hasPrefix("url-") {
            return moduleURL(baseURL: baseURL, moduleName: "url", cmid: remoteID)
        }

        // Page resources.
        if itemID.hasPrefix("page-") {
            return moduleURL(baseURL: baseURL, moduleName: "page", cmid: remoteID)
        }

        // Default: treat as a file resource module.
        return moduleURL(baseURL: baseURL, moduleName: "resource", cmid: remoteID)
    }

    /// Returns the web URL for a course page.
    public static func courseURL(baseURL: URL, courseID: Int) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("course/view.php"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "id", value: String(courseID))]
        return components?.url ?? baseURL
    }

    // MARK: - Private

    private static func moduleURL(baseURL: URL, moduleName: String, cmid: Int) -> URL {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("mod/\(moduleName)/view.php"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "id", value: String(cmid))]
        return components?.url ?? baseURL
    }
}
