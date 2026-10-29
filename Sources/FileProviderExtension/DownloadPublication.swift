import Foundation
import FileProvider
import SharedDomain
import FindlePersistence

enum DownloadPublication {
    static func destination(for item: LocalItem, in directory: URL?) -> URL {
        let root = directory ?? FileManager.default.temporaryDirectory
        let suffix = (item.filename as NSString).pathExtension
        let name = UUID().uuidString + (suffix.isEmpty ? "" : "." + suffix)
        return root.appendingPathComponent(name)
    }

    /// Validate before handing bytes to Finder. A successful HTTP status alone
    /// does not establish that Moodle returned the requested file.
    static func validate(item: LocalItem, response: HTTPURLResponse?, file: URL, cancelled: Bool) throws {
        guard !cancelled else { throw CocoaError(.userCancelled) }
        guard let response else { throw NSFileProviderError(.serverUnreachable) }
        if response.statusCode == 401 { throw NSFileProviderError(.notAuthenticated) }
        if response.statusCode == 403 { throw CocoaError(.fileReadNoPermission) }
        guard response.statusCode == 200 else { throw NSFileProviderError(.serverUnreachable) }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value else { throw CocoaError(.fileReadCorruptFile) }
        if item.fileSize > 0, size != item.fileSize { throw NSFileProviderError(.serverUnreachable) }
        if response.value(forHTTPHeaderField: "Content-Encoding") == nil,
           response.expectedContentLength >= 0, size != response.expectedContentLength {
            throw NSFileProviderError(.serverUnreachable)
        }
        let isHTML = response.mimeType?.lowercased() == "text/html"
        let expectsHTML = item.contentType?.lowercased().contains("html") == true
            || ["html", "htm"].contains((item.filename as NSString).pathExtension.lowercased())
        guard !isHTML || expectsHTML else {
            // An unexpected HTML error/login page is not proof of sign-out.
            throw NSFileProviderError(.serverUnreachable)
        }
    }

    static func publish(
        item: LocalItem, database: Database, response: HTTPURLResponse?, source: URL,
        destination: URL, progress: Progress,
        move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }
    ) throws -> LocalItem {
        try validate(item: item, response: response, file: source, cancelled: progress.isCancelled)
        // Every request gets its own destination. Never delete a previous
        // request's staged file just because two downloads share an item ID.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        do {
            try move(source, destination)
        } catch {
            // A cross-volume move or an injected disk-full error may have
            // created a partial destination before failing.
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: destination) } }
        guard !progress.isCancelled else { throw CocoaError(.userCancelled) }
        guard let updated = try database.updateDownloadState(for: item, state: .materialized, localPath: destination.path) else {
            throw NSFileProviderError(.versionNoLongerAvailable)
        }
        published = true
        return updated
    }
}
