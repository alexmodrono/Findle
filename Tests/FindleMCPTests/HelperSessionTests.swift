import XCTest
import SQLite3
import SharedDomain
import FindlePersistence
import Synchronization

final class HelperSessionTests: XCTestCase {
    @MainActor
    func testProviderLocationDeadlineDoesNotWaitForUncancellableReply() async {
        let reply = Mutex<CheckedContinuation<URL?, Never>?>(nil)
        let clock = ContinuousClock()
        let start = clock.now
        let result = await HelperFileLocation.resolve(timeout: .milliseconds(50)) {
            await withCheckedContinuation { continuation in reply.withLock { $0 = continuation } }
        }
        XCTAssertNil(result)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(2))
        let continuation = reply.withLock { value in let result = value; value = nil; return result }
        XCTAssertNotNil(continuation, "The injected XPC query should have started")
        continuation?.resume(returning: URL(fileURLWithPath: "/late-reply"))
    }

    @MainActor
    func testProviderLocationReturnsPromptReply() async {
        let root = URL(fileURLWithPath: "/disposable-provider-root")
        let result = await HelperFileLocation.resolve { root }
        XCTAssertEqual(result, root)
    }

    private func fixture() throws -> HelperFixture {
        let fixture = try HelperFixture()
        addTeardownBlock { try? FileManager.default.removeItem(at: fixture.directory) }
        return fixture
    }

    func testConfiguredMissingDatabaseNeverFallsBackOrCreatesDatabase() throws {
        let f = try fixture()
        let fallback = try HelperConfiguration(arguments: ["helper"], environment: [:], executableURL: f.executable, homeDirectory: f.directory)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: fallback.databasePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        let other = try TestDB.make(path: fallback.databasePath)
        _ = other
        let session = HelperSession(configuration: try f.configuration(path: f.directory.appendingPathComponent("missing.db").path))
        let result = session.callTool(named: "list_courses", args: emptyArguments)
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.text.contains("CALC"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.configuration.databasePath))
    }

    func testReadsCommittedSyncWritesWithoutWritingMainDatabase() throws {
        let f = try fixture()
        let writer = try TestDB.make(path: f.path)
        let session = HelperSession(configuration: try f.configuration())
        XCTAssertFalse(session.callTool(named: "list_courses", args: emptyArguments).isError)
        try writer.saveCourses([MoodleCourse(id: 300, shortName: "NEW", fullName: "Newly synced", siteID: TestDB.siteID)])
        XCTAssertTrue(session.callTool(named: "list_courses", args: emptyArguments).text.contains("NEW"))
        let result = session.withCatalog { catalog in
            do { try catalog.database.deleteAllData(); XCTFail("Read-only connection deleted data") } catch {}
            do { try catalog.database.setSeedComplete(false); XCTFail("Read-only connection changed seed") } catch {}
            return catalog.callTool(named: "list_courses", args: emptyArguments)
        }
        XCTAssertFalse(result.isError)
        XCTAssertTrue(try writer.isSeedComplete())
        XCTAssertEqual(try writer.fetchCourses(siteID: TestDB.siteID).count, 3)
    }

    func testRetiredDatabaseIsReopenedAndCannotReuseOldIndex() throws {
        let f = try fixture()
        var writer: Database? = try TestDB.make(path: f.path)
        let configuration = try f.configuration()
        let initial = HelperSession(configuration: configuration)
        let session = HelperSession(configuration: configuration, storageRoot: f.directory,
                                    storageAccount: try initial.connectedAccount(), storageSourceIdentity: initial.sourceIdentity)
        _ = session.withCatalog { catalog in
            XCTAssertEqual(catalog.storageRoot?.path, f.directory.path)
            catalog.indexStore?.upsert(itemID: "f1", courseID: 100, filename: "old", content: "old private text", contentVersion: "v1")
            return ("ok", false)
        }
        writer = nil
        try FileManager.default.moveItem(atPath: f.path, toPath: f.path + ".retired")
        writer = try TestDB.make(path: f.path)
        try writer?.saveCourses([MoodleCourse(id: 100, shortName: "REPLACED", fullName: "Replacement", siteID: TestDB.siteID)])
        let result = session.withCatalog { catalog in
            XCTAssertNil(catalog.indexStore?.cachedText(itemID: "f1", contentVersion: "v1"))
            XCTAssertNil(catalog.storageRoot, "Retirement must invalidate the old provider location")
            return catalog.callTool(named: "list_courses", args: emptyArguments)
        }
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.text.contains("REPLACED"))
        XCTAssertFalse(result.text.contains("CALC"))
    }

    func testRetirementDuringReadDiscardsResultAndRecordsSafeFailure() throws {
        let f = try fixture()
        let writer = try TestDB.make(path: f.path)
        _ = writer
        let session = HelperSession(configuration: try f.configuration())
        let result = session.withCatalog { catalog in
            let response = catalog.callTool(named: "list_courses", args: emptyArguments)
            do { try FileManager.default.moveItem(atPath: f.path, toPath: f.path + ".retired") }
            catch { XCTFail("Could not retire disposable database") }
            return response
        }
        XCTAssertTrue(result.isError)
        XCTAssertFalse(result.text.contains("CALC"))
        XCTAssertFalse(result.text.contains(f.path))
        let events = try XCTUnwrap(DiagnosticJournal(databasePath: f.path)).read()
        XCTAssertEqual(events.last?.process, .helper)
        XCTAssertEqual(events.last?.operation, .databaseRead)
        XCTAssertEqual(events.last?.outcome, .failed)
    }

    func testResetAndAccountChangeDiscardInFlightResults() throws {
        let f = try fixture()
        let writer = try TestDB.make(path: f.path)
        let session = HelperSession(configuration: try f.configuration())
        let reset = session.withCatalog { catalog in
            let response = catalog.callTool(named: "list_courses", args: emptyArguments)
            do { try writer.setSeedComplete(false) } catch { XCTFail("Fixture reset failed") }
            return response
        }
        XCTAssertTrue(reset.isError)
        XCTAssertFalse(reset.text.contains("CALC"))
        try writer.setSeedComplete(true)
        XCTAssertFalse(session.callTool(named: "list_courses", args: emptyArguments).isError)
        let switched = session.withCatalog { catalog in
            let response = catalog.callTool(named: "list_courses", args: emptyArguments)
            do { try writer.saveAccount(Account(id: "acc", siteID: TestDB.siteID, userID: 99, state: .authenticated(userID: 99))) }
            catch { XCTFail("Fixture account switch failed") }
            return response
        }
        XCTAssertTrue(switched.isError)
        XCTAssertFalse(switched.text.contains("CALC"))
    }

    func testSchemaUpgradeIsReadOnlyAndRecoversAfterAppMigration() throws {
        let f = try fixture()
        let writer = try TestDB.make(path: f.path)
        _ = writer
        let session = HelperSession(configuration: try f.configuration())
        try executeTestSQL("PRAGMA user_version = \(Database.schemaVersion - 1)", path: f.path)
        XCTAssertTrue(session.callTool(named: "list_courses", args: emptyArguments).isError)
        XCTAssertEqual(DatabaseDiagnostics.capture(path: f.path, siteID: nil).schemaVersion, Database.schemaVersion - 1)
        let migrated = try Database(path: f.path)
        _ = migrated
        XCTAssertFalse(session.callTool(named: "list_courses", args: emptyArguments).isError)
        try executeTestSQL("PRAGMA user_version = \(Database.schemaVersion + 1)", path: f.path)
        XCTAssertTrue(session.callTool(named: "list_courses", args: emptyArguments).isError)
        XCTAssertEqual(DatabaseDiagnostics.capture(path: f.path, siteID: nil).schemaVersion, Database.schemaVersion + 1)
    }

    func testFailedIndexDoesNotDisableCatalogOrMutateMainStore() throws {
        let f = try fixture()
        let writer = try TestDB.make(path: f.path)
        let config = try f.configuration()
        try FileManager.default.createDirectory(at: config.cacheDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: config.cacheDirectory)
        let session = HelperSession(configuration: config)
        XCTAssertFalse(session.callTool(named: "list_courses", args: emptyArguments).isError)
        let search = session.callTool(named: "search_text", args: ArgReader(string: { _ in "private" }, int: { _ in nil }))
        XCTAssertTrue(search.isError)
        XCTAssertTrue(try writer.isSeedComplete())
        XCTAssertEqual(try writer.fetchCourses(siteID: TestDB.siteID).count, 2)
    }

    func testReleaseAndNightlySelectDistinctDataCacheAndDefaultPorts() throws {
        let f = try fixture()
        func config(_ channel: String) throws -> HelperConfiguration {
            try HelperConfiguration(arguments: ["helper", "--channel", channel, "--http"], environment: ["FINDLE_MCP_TOKEN": "test-token"], executableURL: f.executable, homeDirectory: f.directory)
        }
        let release = try config("release")
        let nightly = try config("nightly")
        XCTAssertNotEqual(release.databasePath, nightly.databasePath)
        XCTAssertNotEqual(release.indexPath(generation: "same"), nightly.indexPath(generation: "same"))
        XCTAssertEqual(release.http?.port, 8765)
        XCTAssertEqual(nightly.http?.port, 8766)
        XCTAssertThrowsError(try HTTPOptions.parse(arguments: ["helper", "--http", "-1"], environment: ["FINDLE_MCP_TOKEN": "secret"], defaultPort: 8765))
        XCTAssertThrowsError(try HTTPOptions.parse(arguments: ["helper", "--http"], environment: [:], defaultPort: 8765))
    }

    func testBundledHelperUsesOwningAppIdentityAndRejectsConflictingChannel() throws {
        let f = try fixture()
        let app = f.directory.appendingPathComponent("Findle Nightly.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "es.amodrono.findle.nightly", "CFBundlePackageType": "APPL"], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let executable = contents.appendingPathComponent("MacOS/FindleMCP")
        let config = try HelperConfiguration(arguments: ["helper"], environment: [:], executableURL: executable, homeDirectory: f.directory)
        XCTAssertEqual(config.channel, .nightly)
        XCTAssertEqual(config.applicationURL?.path, app.path)
        XCTAssertTrue(config.databasePath.contains("group.es.amodrono.findle.nightly"))
        XCTAssertThrowsError(try HelperConfiguration(arguments: ["helper", "--channel", "release"], environment: [:], executableURL: executable, homeDirectory: f.directory))
    }
}

private var emptyArguments: ArgReader { ArgReader(string: { _ in nil }, int: { _ in nil }) }

private struct HelperFixture {
    let directory: URL
    var path: String { directory.appendingPathComponent("findle.db").path }
    var executable: URL { directory.appendingPathComponent("FindleMCP") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("helper-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func configuration(path: String? = nil) throws -> HelperConfiguration {
        try HelperConfiguration(arguments: ["helper"], environment: ["FINDLE_DB_PATH": path ?? self.path], executableURL: executable, homeDirectory: directory)
    }
}

func executeTestSQL(_ sql: String, path: String) throws {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { throw POSIXError(.EIO) }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw POSIXError(.EIO) }
}
