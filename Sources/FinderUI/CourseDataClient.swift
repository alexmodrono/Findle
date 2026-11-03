// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import Foundation
import SharedDomain

/// Talks to the File Provider extension's course data service, found through
/// the item the sheet is about, which is the only way into the database.
struct CourseDataClient: Sendable {
    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "Findle couldn't read this course. Open Findle and try again." }
    }

    let domain: NSFileProviderDomainIdentifier
    let item: NSFileProviderItemIdentifier

    private func connect() async throws -> NSXPCConnection {
        guard let match = try await NSFileProviderManager.domains().first(where: { $0.identifier == domain }),
              let manager = NSFileProviderManager(for: match) else { throw Failure.unavailable }
        let url = try await manager.getUserVisibleURL(for: item)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let services = try await FileManager.default.fileProviderServicesForItem(at: url)
        guard let service = services[NSFileProviderServiceName(CourseDataService.serviceName)] else { throw Failure.unavailable }
        let connection = try await service.fileProviderConnection()
        connection.remoteObjectInterface = NSXPCInterface(with: CourseDataSheetsProtocol.self)
        connection.resume()
        return connection
    }

    /// Runs one request. A rejected, crashed or interrupted connection only calls
    /// the error handler, so it ends the request too; whichever comes first wins.
    private func perform<T: Sendable>(
        _ body: (CourseDataSheetsProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let connection = try await connect()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            guard let service = connection.remoteObjectProxyWithErrorHandler({ once.resume(.failure($0)) })
                    as? CourseDataSheetsProtocol else {
                once.resume(.failure(Failure.unavailable))
                return
            }
            body(service) { once.resume($0) }
        }
    }

    private func call<T: Decodable & Sendable>(_ type: T.Type,
                                                _ body: (CourseDataSheetsProtocol, @escaping @Sendable (Data?, Error?) -> Void) -> Void)
        async throws -> T {
        let data: Data = try await perform { service, finish in
            body(service) { data, error in
                finish(data.map { .success($0) } ?? .failure(error ?? Failure.unavailable))
            }
        }
        return try CourseDataService.decode(T.self, from: data)
    }

    func courseInfo(courseID: Int) async throws -> CourseDataService.CourseInfo {
        try await call(CourseDataService.CourseInfo.self) { $0.fetchCourseInfo(courseID: courseID, reply: $1) }
    }

    func assignmentDetails(itemID: String) async throws -> CourseDataService.AssignmentDetails {
        try await call(CourseDataService.AssignmentDetails.self) { $0.fetchAssignmentDetails(itemID: itemID, reply: $1) }
    }

    func submit(itemID: String, acceptStatement: Bool) async throws {
        try await perform { (service, finish: @escaping @Sendable (Result<Void, Error>) -> Void) in
            service.submitAssignment(itemID: itemID, acceptStatement: acceptStatement) { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    func setKeptOffline(courseID: Int, kept: Bool) async throws {
        try await perform { (service, finish: @escaping @Sendable (Result<Void, Error>) -> Void) in
            service.setCourseKeptOffline(courseID: courseID, kept: kept) { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }
}

/// Resumes a continuation once, from a reply or the XPC error handler.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
