// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import ImageIO
import OSLog
import SharedDomain
import FindleNetworking
import FindlePersistence

/// Thumbnails for items that aren't downloaded, from images Moodle renders: a
/// preview of an image file, and the course image on a course folder.
///
/// Moodle only renders previews of images. For any other file it sends a generic
/// icon, which would replace Finder's own, so other items get no thumbnail and
/// keep their normal icon.
final class ThumbnailFetcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = ThumbnailFetcher(configuration: .ephemeral)

    /// Image types Moodle can render a preview of.
    static let previewableTypes: Set<String> = ["image/jpeg", "image/png", "image/gif"]

    private let logger = Logger(subsystem: "com.amodrono.findle.file-provider", category: "Thumbnails")
    private var session: URLSession!

    init(configuration: URLSessionConfiguration) {
        super.init()
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    /// The Moodle image to show for `item`, or nil to keep Finder's normal icon.
    static func source(for item: LocalItem, courseImage: URL?) -> URL? {
        guard !item.isLocal else { return nil }
        if item.isDirectory {
            guard item.id.hasPrefix("course-"), let courseImage else { return nil }
            return preview(of: courseImage)
        }
        guard let mimeType = item.contentType?.lowercased(), previewableTypes.contains(mimeType),
              let remoteURL = item.remoteURL else { return nil }
        return preview(of: remoteURL)
    }

    /// Moodle's 250-pixel rendition, a fraction of the original's size.
    private static func preview(of url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        var query = (components.queryItems ?? []).filter { $0.name != "preview" && $0.name != "forcedownload" }
        query.append(URLQueryItem(name: "preview", value: "bigthumb"))
        components.queryItems = query
        return components.url
    }

    /// Fetches a thumbnail for each identifier. Each one ends with image data, or
    /// with no data and no error when the item has none.
    func fetchThumbnails(
        for identifiers: [NSFileProviderItemIdentifier],
        database: Database,
        siteID: String,
        tokenReader: @escaping (String) throws -> String? = { try KeychainManager.shared.retrieveToken(forAccount: $0) },
        perThumbnail: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completion: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(identifiers.count))
        let batch = ThumbnailBatch(count: identifiers.count, progress: progress,
                                   perThumbnail: perThumbnail, completion: completion)
        guard !identifiers.isEmpty else {
            batch.finishIfDone()
            return progress
        }

        let sources: [(NSFileProviderItemIdentifier, URL?)]
        let credentials: (AuthenticatedRequestOrigin, AuthToken)?
        do {
            let courseImages = Dictionary(
                try database.fetchCourses(siteID: siteID).compactMap { course in course.imageURL.map { (course.id, $0) } },
                uniquingKeysWith: { first, _ in first })
            sources = try identifiers.map { identifier in
                guard let item = try database.fetchItem(id: identifier.rawValue), item.siteID == siteID else {
                    return (identifier, nil)
                }
                return (identifier, Self.source(for: item, courseImage: courseImages[item.courseID]))
            }
            credentials = sources.contains { $0.1 != nil } ? try Self.credentials(siteID: siteID, database: database, tokenReader: tokenReader) : nil
        } catch {
            logger.error("Thumbnails unavailable: \(DiagnosticFailure(error).summary, privacy: .public)")
            for identifier in identifiers { batch.deliver(identifier, nil, NSFileProviderError(.serverUnreachable)) }
            return progress
        }

        for (identifier, url) in sources {
            guard let url, let (origin, token) = credentials,
                  let request = try? origin.fileRequest(url: url, token: token) else {
                batch.deliver(identifier, nil, nil)
                continue
            }
            let task = session.dataTask(with: request) { data, response, error in
                batch.deliver(identifier, Self.image(from: data, response: response),
                              error.map(Self.mapTransportError))
            }
            batch.track(task)
            task.resume()
        }
        return progress
    }

    private static func credentials(
        siteID: String, database: Database, tokenReader: (String) throws -> String?
    ) throws -> (AuthenticatedRequestOrigin, AuthToken)? {
        guard let site = try database.fetchSite(id: siteID),
              let origin = try? AuthenticatedRequestOrigin(site: site) else { return nil }
        let accountID = try database.fetchAccounts().first { $0.siteID == siteID }?.id ?? siteID
        guard let token = try tokenReader(accountID) else { return nil }
        return (origin, AuthToken(token: token))
    }

    /// Only an image is a thumbnail. Moodle answers some failures with an HTML or
    /// JSON page and a 200 status.
    static func image(from data: Data?, response: URLResponse?) -> Data? {
        guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return data
    }

    private static func mapTransportError(_ error: Error) -> Error {
        (error as? URLError)?.code == .cancelled ? CocoaError(.userCancelled) : NSFileProviderError(.serverUnreachable)
    }

    /// The credentials go in the request body, so a redirect is never followed.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Reports each thumbnail once, then the whole request once.
private final class ThumbnailBatch: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var tasks: [URLSessionTask] = []
    private var finished = false
    private let progress: Progress
    private let perThumbnail: (NSFileProviderItemIdentifier, Data?, Error?) -> Void
    private let completion: (Error?) -> Void

    init(count: Int, progress: Progress,
         perThumbnail: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
         completion: @escaping (Error?) -> Void) {
        remaining = count
        self.progress = progress
        self.perThumbnail = perThumbnail
        self.completion = completion
        progress.cancellationHandler = { [weak self] in self?.cancel() }
    }

    func track(_ task: URLSessionTask) {
        lock.withLock { tasks.append(task) }
    }

    /// Handlers run under the lock, so the whole request never ends before a
    /// thumbnail that is still being reported.
    func deliver(_ identifier: NSFileProviderItemIdentifier, _ data: Data?, _ error: Error?) {
        lock.withLock {
            guard !finished else { return }
            perThumbnail(identifier, data, data == nil ? error : nil)
            remaining -= 1
            progress.completedUnitCount += 1
            finishLocked()
        }
    }

    func finishIfDone() {
        lock.withLock { finishLocked() }
    }

    private func finishLocked() {
        guard remaining <= 0, !finished else { return }
        finished = true
        completion(nil)
    }

    private func cancel() {
        let running = lock.withLock { () -> [URLSessionTask] in
            guard !finished else { return [] }
            finished = true
            completion(CocoaError(.userCancelled))
            return tasks
        }
        running.forEach { $0.cancel() }
    }
}
