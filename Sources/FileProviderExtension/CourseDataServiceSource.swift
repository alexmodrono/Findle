// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import OSLog
import Security
import SharedDomain
import FindlePersistence

/// Vends `CourseDataService` from the File Provider extension, which is the only
/// process that can open the database. Read-only: it never writes.
final class CourseDataServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, @unchecked Sendable {
    /// Decides whether a connecting process may read course data.
    typealias Admission = @Sendable (NSXPCConnection) -> Bool

    let serviceName = NSFileProviderServiceName(CourseDataService.serviceName)

    private let lock = NSLock()
    private var listener: NSXPCListener?
    private let source: @Sendable () -> (database: Database, siteID: String)?
    private let admits: Admission
    private let logger = Logger(subsystem: "es.amodrono.findle.file-provider", category: "CourseData")

    /// `source` is read on every request, so a reopened database is picked up.
    init(source: @escaping @Sendable () -> (database: Database, siteID: String)?,
         admission: @escaping Admission = CourseDataServiceSource.sameTeamAdmission()) {
        self.source = source
        self.admits = admission
    }

    func makeListenerEndpoint() throws -> NSXPCListenerEndpoint {
        lock.lock()
        defer { lock.unlock() }
        if let listener { return listener.endpoint }
        let listener = NSXPCListener.anonymous()
        listener.delegate = self
        listener.resume()
        self.listener = listener
        return listener.endpoint
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        listener?.invalidate()
        listener = nil
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard admits(connection) else {
            logger.warning("Rejected a course data connection from process \(connection.processIdentifier, privacy: .public)")
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: CourseDataServiceProtocol.self)
        connection.exportedObject = CourseDataExport(source: source)
        connection.resume()
        return true
    }

    /// Admits processes signed by the extension's own team, enforced by the
    /// system on every message. A build without a team (ad hoc or unsigned)
    /// admits nobody, rather than anyone.
    static func sameTeamAdmission(teamID: String? = ownTeamID()) -> Admission {
        { connection in
            guard let teamID, teamID.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
            connection.setCodeSigningRequirement("anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"")
            return true
        }
    }

    static func ownTeamID() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let dictionary = information as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// The object each admitted connection talks to.
private final class CourseDataExport: NSObject, CourseDataServiceProtocol, @unchecked Sendable {
    private let source: @Sendable () -> (database: Database, siteID: String)?

    init(source: @escaping @Sendable () -> (database: Database, siteID: String)?) {
        self.source = source
    }

    func fetchCourses(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        respond(reply) { database, siteID in
            CourseDataService.courses(from: try database.fetchCourses(siteID: siteID))
        }
    }

    func fetchUpcomingCoursework(reply: @escaping @Sendable (Data?, Error?) -> Void) {
        respond(reply) { database, siteID in
            CourseDataService.upcomingCoursework(
                courses: try database.fetchCourses(siteID: siteID),
                assignments: try database.fetchAssignments(siteID: siteID),
                quizzes: try database.fetchQuizzes(siteID: siteID))
        }
    }

    /// Errors cross XPC as File Provider errors, without database details.
    private func respond<T: Encodable>(
        _ reply: @Sendable (Data?, Error?) -> Void, _ read: (Database, String) throws -> T
    ) {
        guard let (database, siteID) = source() else {
            reply(nil, NSFileProviderError(.serverUnreachable) as NSError)
            return
        }
        do {
            reply(try CourseDataService.encode(read(database, siteID)), nil)
        } catch {
            reply(nil, NSFileProviderError(.serverUnreachable) as NSError)
        }
    }
}
