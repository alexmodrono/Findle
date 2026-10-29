import XCTest
import Darwin
@testable import SharedDomain

final class DiagnosticsTests: XCTestCase {
    func testErrorsKeepUsefulCodesWithoutCredentialOrPathDetails() throws {
        let secret = "token-SENSITIVE-password"
        let errors: [any Error] = [
            NSError(domain: "NSFileProviderErrorDomain", code: -2005, userInfo: [
                NSLocalizedDescriptionKey: secret, NSFilePathErrorKey: "/Users/private/notes",
                NSUnderlyingErrorKey: NSError(domain: secret, code: 42)
            ]),
            NSError(domain: secret, code: 7),
            FindleError.requestFailed(statusCode: 503, detail: "https://example.edu?token=\(secret)"),
            FindleError.ssoCallbackInvalid(detail: secret),
            FindleError.databaseError(detail: "/Users/private/\(secret)"),
            FindleError.downloadFailed(itemID: secret, reason: secret)
        ]
        let data = try JSONEncoder().encode(errors.map(DiagnosticFailure.init))
        let text = String(decoding: data, as: UTF8.self)
        for forbidden in [secret, "/Users", "example.edu", "underlying", "userInfo"] {
            XCTAssertFalse(text.contains(forbidden), text)
        }
        XCTAssertEqual(DiagnosticFailure(errors[0]).domain, "NSFileProviderErrorDomain")
        XCTAssertEqual(DiagnosticFailure(errors[0]).code, -2005)
        XCTAssertEqual(DiagnosticFailure(errors[2]).code, 503)
        XCTAssertEqual(DiagnosticFailure(errors[1]).domain, "Other")
    }

    func testOldOrTamperedJournalCannotInjectUnredactedFailureStrings() throws {
        let data = Data(#"{"domain":"token-secret","kind":"/Users/private/password","code":-2005}"#.utf8)
        let failure = try JSONDecoder().decode(DiagnosticFailure.self, from: data)
        XCTAssertEqual(failure.domain, "Other")
        XCTAssertEqual(failure.kind, "error")
        XCTAssertEqual(failure.code, -2005)
    }

    func testBoundedJournalKeepsCorrelationAcrossProcessWriters() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = DiagnosticJournal(directory: root)
        let provider = DiagnosticJournal(directory: root)
        let attempt = UUID()
        for _ in 0..<200 {
            XCTAssertTrue(host.record(.init(process: .app, operation: .sync, outcome: .succeeded)))
        }
        XCTAssertTrue(host.record(.init(attemptID: attempt, process: .app, operation: .providerRegistration, outcome: .started)))
        XCTAssertTrue(provider.record(.init(attemptID: attempt, process: .fileProvider, operation: .databaseOpen,
                                            outcome: .failed, failure: DiagnosticFailure(NSError(domain: "SQLite", code: 14)))))
        let events = try host.read()
        XCTAssertEqual(events.count, DiagnosticJournal.maximumEvents)
        XCTAssertEqual(events.suffix(2).map(\.attemptID), [attempt, attempt])
        XCTAssertEqual(events.last?.failure?.code, 14)
        let permissions = try FileManager.default.attributesOfItem(atPath: host.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testBusyOrLinkedJournalNeverBlocksOrDamagesAnotherFile() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(directory: root)
        let event = DiagnosticEvent(process: .app, operation: .sync, outcome: .started)
        XCTAssertTrue(journal.record(event))
        let fd = open(journal.url.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        XCTAssertFalse(journal.record(event))
        XCTAssertThrowsError(try journal.read())
        flock(fd, LOCK_UN)
        let original = Data("personal file".utf8)
        let personal = root.appendingPathComponent("personal")
        try original.write(to: personal)
        try FileManager.default.removeItem(at: journal.url)
        try FileManager.default.createSymbolicLink(at: journal.url, withDestinationURL: personal)
        XCTAssertFalse(journal.record(event))
        try FileManager.default.removeItem(at: journal.url)
        XCTAssertEqual(link(personal.path, journal.url.path), 0)
        XCTAssertFalse(journal.record(event))
        XCTAssertEqual(try Data(contentsOf: personal), original)
    }

    func testTornOrOversizedJournalRecoversOnNextEvent() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(directory: root)
        for invalid in [Data("[partial".utf8), Data(repeating: 65, count: 256 * 1024)] {
            try invalid.write(to: journal.url)
            XCTAssertThrowsError(try journal.read())
            let event = DiagnosticEvent(process: .fileProvider, operation: .download, outcome: .failed,
                                        failure: DiagnosticFailure(URLError(.timedOut)))
            XCTAssertTrue(journal.record(event))
            XCTAssertEqual(try journal.read(), [event])
        }
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
