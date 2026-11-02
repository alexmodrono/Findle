// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import FileProvider
import OSLog
import Security
import SharedDomain
import FindlePersistence
import FindleNetworking

/// Vends `CourseDataService` from the File Provider extension, which is the only
/// process that can open the database. Read-only: it never writes.
final class CourseDataServiceSource: NSObject, NSFileProviderServiceSource, NSXPCListenerDelegate, @unchecked Sendable {
    /// Decides whether a connecting process may read course data.
    typealias Admission = @Sendable (NSXPCConnection) -> Bool

    let serviceName = NSFileProviderServiceName(CourseDataService.serviceName)

    private let lock = NSLock()
    private var listener: NSXPCListener?
    private let source: @Sendable () -> (database: Database, siteID: String)?
    /// Keeps a course downloaded or lets it go, as Finder's action does.
    private let keep: @Sendable (Int, Bool) throws -> Void
    private let admits: Admission
    private let logger = Logger(subsystem: "es.amodrono.findle.file-provider", category: "CourseData")

    /// `source` is read on every request, so a reopened database is picked up.
    init(source: @escaping @Sendable () -> (database: Database, siteID: String)?,
         keep: @escaping @Sendable (Int, Bool) throws -> Void = { _, _ in },
         admission: @escaping Admission = CourseDataServiceSource.sameTeamAdmission()) {
        self.source = source
        self.keep = keep
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
        connection.exportedInterface = NSXPCInterface(with: CourseDataSheetsProtocol.self)
        connection.exportedObject = CourseDataExport(source: source, keep: keep)
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
private final class CourseDataExport: NSObject, CourseDataSheetsProtocol, @unchecked Sendable {
    private let source: @Sendable () -> (database: Database, siteID: String)?
    private let keep: @Sendable (Int, Bool) throws -> Void

    init(source: @escaping @Sendable () -> (database: Database, siteID: String)?,
         keep: @escaping @Sendable (Int, Bool) throws -> Void) {
        self.source = source
        self.keep = keep
    }

    func fetchCourseInfo(courseID: Int, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        respond(reply) { database, siteID in
            guard let course = try database.fetchCourses(siteID: siteID).first(where: { $0.id == courseID }) else {
                throw NSFileProviderError(.noSuchItem)
            }
            return CourseDataService.courseInfo(
                course: course, teachers: try database.fetchCourseTeachers(courseID: courseID, siteID: siteID),
                outline: try database.fetchCourseOutline(courseID: courseID, siteID: siteID),
                lastSync: try database.fetchSyncCursor(courseID: courseID, siteID: siteID)?.lastSyncDate,
                items: try database.fetchItems(courseID: courseID, siteID: siteID),
                keptPreviousBytes: try database.previousVersionBytes(courseID: courseID, siteID: siteID))
        }
    }

    func fetchAssignmentDetails(itemID: String, reply: @escaping @Sendable (Data?, Error?) -> Void) {
        respond(reply) { database, siteID in
            guard itemID.hasPrefix("assign-"), let folder = try database.fetchItem(id: itemID), folder.siteID == siteID else {
                throw NSFileProviderError(.noSuchItem)
            }
            let assignment = try database.fetchAssignments(siteID: siteID)
                .first { $0.courseID == folder.courseID && $0.moduleID == folder.remoteID }
            let courseName = try database.fetchCourses(siteID: siteID).first { $0.id == folder.courseID }?.fullName ?? ""
            let brief = try database.fetchGeneratedContent(itemID: "brief-\(siteID)-\(folder.courseID)-\(folder.remoteID)")
                .map { String(decoding: $0, as: UTF8.self) }
            let draft = try database.fetchItems(parentID: "submit-\(siteID)-\(folder.courseID)-\(folder.remoteID)", siteID: siteID)
                .filter { $0.isLocal && !$0.isDirectory }.map(\.filename).sorted()
            return CourseDataService.assignmentDetails(folder: folder, assignment: assignment, courseName: courseName,
                                                       brief: brief, draftFiles: draft)
        }
    }

    func submitAssignment(itemID: String, acceptStatement: Bool, reply: @escaping @Sendable (Error?) -> Void) {
        guard let (database, siteID) = source(), itemID.hasPrefix("assign-"),
              let folder = try? database.fetchItem(id: itemID), folder.siteID == siteID,
              let site = try? database.fetchSite(id: siteID),
              let assignment = (try? database.fetchAssignments(siteID: siteID))?
                .first(where: { $0.courseID == folder.courseID && $0.moduleID == folder.remoteID }), assignment.canSubmit else {
            reply(NSFileProviderError(.noSuchItem) as NSError)
            return
        }
        let accountID = (try? database.fetchAccounts())?.first { $0.siteID == siteID }?.id ?? siteID
        guard let token = try? KeychainManager.shared.retrieveToken(forAccount: accountID) else {
            reply(NSFileProviderError(.notAuthenticated) as NSError)
            return
        }
        Task {
            do {
                try await MoodleClient().submitForGrading(site: site, token: AuthToken(token: token), assignmentID: assignment.id,
                                                          acceptStatement: acceptStatement)
                reply(nil)
            } catch {
                reply(NSFileProviderError(.serverUnreachable) as NSError)
            }
        }
    }

    func setCourseKeptOffline(courseID: Int, kept: Bool, reply: @escaping @Sendable (Error?) -> Void) {
        do {
            try keep(courseID, kept)
            reply(nil)
        } catch {
            reply(NSFileProviderError(.serverUnreachable) as NSError)
        }
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
