import Foundation
import Darwin

/// Diagnostics deliberately retain codes, not descriptions, URLs, paths, or userInfo.
/// A server error or callback can contain credentials even when it looks like prose.
public struct DiagnosticFailure: Codable, Equatable, Sendable {
    public let domain: String
    public let code: Int
    public let kind: String
    public var summary: String { "\(domain) (\(code)): \(kind)" }

    public init(_ error: any Error) {
        if let error = error as? FindleError {
            var domain = "Findle"
            var code = 0
            let kind: String
            switch error {
            case .invalidCredentials: kind = "invalidCredentials"
            case .tokenExpired: kind = "tokenExpired"
            case .tokenRefreshFailed: kind = "tokenRefreshFailed"
            case .authenticationRequired: kind = "authenticationRequired"
            case .siteUnreachable: kind = "siteUnreachable"
            case .siteIncompatible: kind = "siteIncompatible"
            case .webServicesDisabled: kind = "webServicesDisabled"
            case .insufficientPermissions: kind = "insufficientPermissions"
            case .networkUnavailable: kind = "networkUnavailable"
            case .requestFailed(let status, _):
                domain = "HTTP"; code = status; kind = "requestFailed"
            case .invalidResponse: kind = "invalidResponse"
            case .timeout: kind = "timeout"
            case .syncFailed: kind = "syncFailed"
            case .conflictDetected: kind = "conflictDetected"
            case .itemNotFound: kind = "itemNotFound"
            case .downloadFailed: kind = "downloadFailed"
            case .databaseError: kind = "databaseError"
            case .migrationFailed: kind = "migrationFailed"
            case .domainSetupFailed: kind = "domainSetupFailed"
            case .enumerationFailed: kind = "enumerationFailed"
            case .ssoLaunchURLUnavailable: kind = "ssoLaunchURLUnavailable"
            case .ssoLaunchURLInvalid: kind = "ssoLaunchURLInvalid"
            case .ssoCallbackInvalid: kind = "ssoCallbackInvalid"
            case .ssoSessionStartFailed: kind = "ssoSessionStartFailed"
            case .internalError: kind = "internalError"
            case .cancelled: kind = "cancelled"
            }
            self.init(domain: domain, code: code, kind: kind)
        } else if error is CancellationError {
            self.init(domain: "Swift", code: 0, kind: "cancelled")
        } else {
            let error = error as NSError
            let allowedDomains: Set<String> = [
                NSCocoaErrorDomain, NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                "NSFileProviderErrorDomain", "NSFileProviderInternalErrorDomain", "SQLite",
                "ASWebAuthenticationSessionErrorDomain", "WKErrorDomain"
            ]
            self.init(domain: allowedDomains.contains(error.domain) ? error.domain : "Other",
                      code: error.code, kind: "error")
        }
    }

    private init(domain: String, code: Int, kind: String) {
        self.domain = domain
        self.code = code
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case domain, code, kind }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let domain = try values.decode(String.self, forKey: .domain)
        let kind = try values.decode(String.self, forKey: .kind)
        let domains: Set<String> = ["Findle", "HTTP", "Swift", "Other", NSCocoaErrorDomain,
                                   NSURLErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                                   "NSFileProviderErrorDomain", "NSFileProviderInternalErrorDomain", "SQLite",
                                   "ASWebAuthenticationSessionErrorDomain", "WKErrorDomain"]
        let kinds: Set<String> = ["error", "invalidCredentials", "tokenExpired", "tokenRefreshFailed",
            "authenticationRequired", "siteUnreachable", "siteIncompatible", "webServicesDisabled",
            "insufficientPermissions", "networkUnavailable", "requestFailed", "invalidResponse", "timeout",
            "syncFailed", "conflictDetected", "itemNotFound", "downloadFailed", "databaseError", "migrationFailed",
            "domainSetupFailed", "enumerationFailed", "ssoLaunchURLUnavailable", "ssoLaunchURLInvalid",
            "ssoCallbackInvalid", "ssoSessionStartFailed", "internalError", "cancelled"]
        self.init(domain: domains.contains(domain) ? domain : "Other",
                  code: try values.decode(Int.self, forKey: .code), kind: kinds.contains(kind) ? kind : "error")
    }
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public enum Process: String, Codable, Sendable { case app, fileProvider, helper }
    public enum Operation: String, Codable, Sendable {
        case sync, providerRegistration, providerReset, databaseOpen, databaseRead
        case download, enumeration, personalFiles, authentication, diagnosticsExport
    }
    public enum Outcome: String, Codable, Sendable { case started, succeeded, failed, cancelled, partial }

    public let id: UUID
    public let attemptID: UUID
    /// Most recent host operation observed when this extension operation began.
    /// This is context, not a claim that the host caused the failure.
    public let relatedAttemptID: UUID?
    public let timestamp: Date
    public let process: Process
    public let operation: Operation
    public let outcome: Outcome
    public let failure: DiagnosticFailure?

    public init(attemptID: UUID = UUID(), relatedAttemptID: UUID? = nil, process: Process, operation: Operation,
                outcome: Outcome, failure: DiagnosticFailure? = nil, timestamp: Date = Date()) {
        id = UUID()
        self.attemptID = attemptID
        self.relatedAttemptID = relatedAttemptID
        self.timestamp = timestamp
        self.process = process
        self.operation = operation
        self.outcome = outcome
        self.failure = failure
    }
}

/// A small best-effort journal shared by the host and extension next to their database.
/// All processes lock the same inode; no replace/rename race can lose another writer.
/// Busy logging is skipped rather than delaying Finder or a recovery operation.
public struct DiagnosticJournal: Sendable {
    public static let maximumEvents = 128
    private static let maximumBytes = 128 * 1024
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("findle-diagnostics.json")
    }

    public init?(databasePath: String?) {
        guard let databasePath, databasePath != ":memory:" else { return nil }
        self.init(directory: URL(fileURLWithPath: databasePath).deletingLastPathComponent())
    }

    public func read() throws -> [DiagnosticEvent] {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return [] }
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        try checkRegularFile(fd)
        guard flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw POSIXError(.EBUSY) }
        defer { flock(fd, LOCK_UN) }
        return try readEvents(fd)
    }

    @discardableResult
    public func record(_ event: DiagnosticEvent) -> Bool {
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        do {
            try checkRegularFile(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
            defer { flock(fd, LOCK_UN) }
            guard fchmod(fd, S_IRUSR | S_IWUSR) == 0 else { return false }
            // A torn diagnostics write must never prevent recording the next failure.
            var events = (try? readEvents(fd)) ?? []
            events.append(event)
            events = Array(events.suffix(Self.maximumEvents))
            let data = try JSONEncoder().encode(events)
            guard data.count <= Self.maximumBytes else { return false }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
            return true
        } catch { return false }
    }

    private func checkRegularFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw POSIXError(.EINVAL) }
        // A hard link must not let diagnostic writes truncate an unrelated file.
        guard info.st_nlink == 1 else { throw POSIXError(.EMLINK) }
    }

    private func readEvents(_ fd: Int32) throws -> [DiagnosticEvent] {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw POSIXError(.EFBIG) }
        if data.isEmpty { return [] }
        return Array(try JSONDecoder().decode([DiagnosticEvent].self, from: data).suffix(Self.maximumEvents))
    }
}

public struct DiagnosticDatabaseSnapshot: Codable, Sendable {
    public struct CourseCursor: Codable, Sendable {
        public let courseID: Int
        public let lastSuccess: Date
        public init(courseID: Int, lastSuccess: Date) { self.courseID = courseID; self.lastSuccess = lastSuccess }
    }
    public let schemaVersion: Int?
    public let state: String
    public let seedComplete: Bool?
    public let changeCounter: Int64?
    public let cursors: [CourseCursor]
    public let failure: DiagnosticFailure?

    public init(schemaVersion: Int? = nil, seedComplete: Bool? = nil, changeCounter: Int64? = nil,
                cursors: [CourseCursor] = [], failure: DiagnosticFailure? = nil) {
        self.schemaVersion = schemaVersion; self.seedComplete = seedComplete
        state = schemaVersion != nil && failure == nil ? "available" : "unavailable"
        self.changeCounter = changeCounter; self.cursors = cursors; self.failure = failure
    }
}

public struct DiagnosticProviderSnapshot: Codable, Sendable {
    public enum State: String, Codable, Sendable { case registered, notRegistered, unavailable, timedOut }
    public let state: State
    public let failure: DiagnosticFailure?
    public init(state: State, failure: DiagnosticFailure? = nil) { self.state = state; self.failure = failure }
}

public struct DiagnosticCourseOutcome: Codable, Sendable {
    public let courseID: Int
    public let outcome: String
    public let failure: DiagnosticFailure?
    public init(courseID: Int, outcome: String, failure: DiagnosticFailure? = nil) {
        self.courseID = courseID
        // Only controlled outcome values cross the export boundary.
        self.outcome = ["succeeded", "failed", "incomplete", "cancelled", "skipped"].contains(outcome) ? outcome : "unknown"
        self.failure = failure
    }
}

public struct StabilityDiagnosticReport: Encodable, Sendable {
    public let formatVersion = 1
    public let timestamp: Date
    public let appVersion: String
    public let appBuild: String
    public let revision: String?
    public let channel: String
    public let operatingSystem: String
    public let architecture: String
    public let syncState: String
    public let lastSuccessfulSync: Date?
    public let syncAttemptID: UUID?
    public let courses: [DiagnosticCourseOutcome]
    public let database: DiagnosticDatabaseSnapshot
    public let provider: DiagnosticProviderSnapshot
    public let events: [DiagnosticEvent]
    public let journalFailure: DiagnosticFailure?

    public init(appVersion: String, appBuild: String, revision: String?, channel: String,
                syncState: String, lastSuccessfulSync: Date?, syncAttemptID: UUID?,
                courses: [DiagnosticCourseOutcome], database: DiagnosticDatabaseSnapshot,
                provider: DiagnosticProviderSnapshot, events: [DiagnosticEvent], journalFailure: DiagnosticFailure?) {
        timestamp = Date()
        func version(_ value: String) -> String {
            let allowed = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+")
            return value.count <= 64 && value.unicodeScalars.allSatisfy(allowed.contains) ? value : "unknown"
        }
        self.appVersion = version(appVersion); self.appBuild = version(appBuild)
        self.revision = revision.flatMap { value in
            (7...40).contains(value.count) && value.allSatisfy(\.isHexDigit) ? value : nil
        }
        self.channel = ["release", "nightly", "debug"].contains(channel) ? channel : "unknown"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        operatingSystem = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        architecture = "arm64"
        #else
        architecture = "x86_64"
        #endif
        self.syncState = ["idle", "syncing", "completed", "partial", "error"].contains(syncState) ? syncState : "unknown"
        self.lastSuccessfulSync = lastSuccessfulSync; self.syncAttemptID = syncAttemptID
        self.courses = courses; self.database = database; self.provider = provider
        self.events = Array(events.suffix(DiagnosticJournal.maximumEvents)); self.journalFailure = journalFailure
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
