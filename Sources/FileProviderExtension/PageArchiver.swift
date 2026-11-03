// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import Foundation
import OSLog
import SharedDomain
import FindleNetworking
import FindlePersistence

/// Saves a Moodle page as a web archive: its HTML with the images it shows, so
/// it opens offline and previews with Quick Look. Moodle serves those images
/// only with the user's credentials, which a browser opening bare HTML lacks.
enum PageArchiver {
    private static let logger = Logger(subsystem: "com.amodrono.findle.file-provider", category: "PageArchive")
    /// Bounds on what one page may pull in, so a huge page can't stall Finder.
    static let maxResources = 60
    static let maxResourceBytes = 50 * 1024 * 1024

    static func isPage(_ item: LocalItem) -> Bool {
        item.id.hasPrefix("page-") && (item.filename as NSString).pathExtension.lowercased() == "webarchive"
    }

    // MARK: - Building

    /// The images the page shows from its own files on Moodle, each with the URL
    /// the page names it by (what the archive files it under) and the URL to
    /// fetch it from with the user's token. Other sites' images stay links.
    static func resources(in html: String, pageURL: URL, origin: AuthenticatedRequestOrigin) -> [(archived: URL, fetch: URL)] {
        guard let pattern = try? NSRegularExpression(
            pattern: #"<img\b[^>]*?\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)')"#, options: [.caseInsensitive]) else { return [] }
        var seen = Set<String>()
        var found: [(URL, URL)] = []
        let range = NSRange(html.startIndex..., in: html)
        for match in pattern.matches(in: html, range: range) {
            let group = match.range(at: 1).location != NSNotFound ? 1 : 2
            guard let srcRange = Range(match.range(at: group), in: html) else { continue }
            let src = String(html[srcRange]).replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !src.isEmpty, !src.lowercased().hasPrefix("data:"),
                  let url = (URL(string: src, relativeTo: pageURL)
                      ?? src.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap { URL(string: $0, relativeTo: pageURL) })?
                      .absoluteURL,
                  let fetch = fetchURL(for: url, origin: origin),
                  seen.insert(url.absoluteString).inserted else { continue }
            found.append((url, fetch))
            if found.count == maxResources { break }
        }
        return found
    }

    /// Only Moodle's own files are fetched with the token. Browser-style
    /// pluginfile links need a session, so they go through the web service.
    static func fetchURL(for url: URL, origin: AuthenticatedRequestOrigin) -> URL? {
        guard (try? origin.validate(url)) != nil,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        let path = components.percentEncodedPath
        if path.contains("/webservice/pluginfile.php/") { return url }
        guard let range = path.range(of: "/pluginfile.php/") else { return nil }
        components.percentEncodedPath = path.replacingCharacters(in: range, with: "/webservice/pluginfile.php/")
        return components.url
    }

    struct Resource {
        let url: URL
        let data: Data
        let mimeType: String
    }

    /// A Safari web archive: the page as its main resource, its images as
    /// subresources under the URLs the page names them by.
    static func archive(html: Data, pageURL: URL, textEncoding: String?, resources: [Resource]) throws -> Data {
        var main: [String: Any] = [
            "WebResourceData": html,
            "WebResourceFrameName": "",
            "WebResourceMIMEType": "text/html",
            "WebResourceURL": pageURL.absoluteString,
        ]
        main["WebResourceTextEncodingName"] = textEncoding ?? "UTF-8"
        var archive: [String: Any] = ["WebMainResource": main]
        if !resources.isEmpty {
            archive["WebSubresources"] = resources.map {
                ["WebResourceData": $0.data, "WebResourceMIMEType": $0.mimeType, "WebResourceURL": $0.url.absoluteString]
            }
        }
        return try PropertyListSerialization.data(fromPropertyList: archive, format: .binary, options: 0)
    }

    // MARK: - Downloading

    /// Downloads the page and its images and publishes the archive. The caller
    /// has validated `pageURL` against `origin` and marked the item downloading.
    static func start(
        item: LocalItem, pageURL: URL, origin: AuthenticatedRequestOrigin, token: AuthToken,
        database: Database, destination: URL, progress: Progress, bridge: FileDownloadCompletionBridge
    ) {
        nonisolated(unsafe) let progress = progress
        progress.totalUnitCount = 100
        let task = Task {
            let session = URLSession(configuration: .ephemeral, delegate: RedirectRefusal(), delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            do {
                let (html, response) = try await session.data(for: origin.fileRequest(url: pageURL, token: token))
                try check(response, allowing: { $0.hasPrefix("text/html") || $0 == "application/octet-stream" })
                progress.completedUnitCount = 10

                let text = String(decoding: html, as: UTF8.self)
                let wanted = resources(in: text, pageURL: pageURL, origin: origin)
                var fetched: [Resource] = []
                var bytes = 0
                for (index, resource) in wanted.enumerated() {
                    try Task.checkCancellation()
                    // A missing image leaves a gap in the page, not a failed download.
                    if let (data, response) = try? await session.data(for: origin.fileRequest(url: resource.fetch, token: token)),
                       (try? check(response, allowing: { $0.hasPrefix("image/") })) != nil,
                       bytes + data.count <= maxResourceBytes {
                        bytes += data.count
                        fetched.append(Resource(url: resource.archived, data: data,
                                                mimeType: response.mimeType ?? "application/octet-stream"))
                    }
                    progress.completedUnitCount = 10 + Int64(80 * (index + 1) / max(wanted.count, 1))
                }
                try Task.checkCancellation()
                let archive = try archive(html: html, pageURL: pageURL, textEncoding: response.textEncodingName,
                                          resources: fetched)
                let updated = try DownloadPublication.publishGenerated(
                    archive, item: item, database: database, destination: destination, progress: progress)
                progress.completedUnitCount = 100
                logger.info("Saved a page with \(fetched.count, privacy: .public) of \(wanted.count, privacy: .public) images")
                bridge.succeed(url: destination, item: FileProviderItem(localItem: updated))
            } catch {
                DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                    process: .fileProvider, operation: .download, outcome: .failed, failure: DiagnosticFailure(error)))
                FileDownloader.resetToPlaceholderIfNeeded(item: item, database: database)
                bridge.fail(mapError(error))
            }
        }
        progress.cancellationHandler = { task.cancel() }
    }

    private static func check(_ response: URLResponse, allowing mimeType: (String) -> Bool) throws {
        guard let http = response as? HTTPURLResponse else { throw NSFileProviderError(.serverUnreachable) }
        if http.statusCode == 401 { throw NSFileProviderError(.notAuthenticated) }
        if http.statusCode == 403 { throw CocoaError(.fileReadNoPermission) }
        guard http.statusCode == 200 else { throw NSFileProviderError(.serverUnreachable) }
        // Moodle answers some failures with a JSON error and a 200 status.
        guard mimeType(http.mimeType?.lowercased() ?? "") else { throw NSFileProviderError(.serverUnreachable) }
    }

    private static func mapError(_ error: Error) -> Error {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return CocoaError(.userCancelled) }
        let domain = (error as NSError).domain
        if domain == NSFileProviderErrorDomain || domain == NSCocoaErrorDomain { return error }
        return NSFileProviderError(.serverUnreachable)
    }
}

/// The token travels in the request body, so a redirect is never followed.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
