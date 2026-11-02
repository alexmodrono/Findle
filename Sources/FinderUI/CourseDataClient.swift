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

    private func proxy() async throws -> (CourseDataSheetsProtocol, NSXPCConnection) {
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
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in }) as? CourseDataSheetsProtocol else {
            connection.invalidate()
            throw Failure.unavailable
        }
        return (proxy, connection)
    }

    private func call<T: Decodable & Sendable>(_ type: T.Type,
                                                _ body: (CourseDataSheetsProtocol, @escaping @Sendable (Data?, Error?) -> Void) -> Void)
        async throws -> T {
        let (service, connection) = try await proxy()
        defer { connection.invalidate() }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            body(service) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? Failure.unavailable) }
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

    func setKeptOffline(courseID: Int, kept: Bool) async throws {
        let (service, connection) = try await proxy()
        defer { connection.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            service.setCourseKeptOffline(courseID: courseID, kept: kept) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}
