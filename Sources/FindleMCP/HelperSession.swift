import Foundation
import Darwin
import FindlePersistence
import SharedDomain

/// Each tool gets a new query-only handle. No SQLite handle survives a request,
/// and a response is discarded if the source was retired while the tool ran.
/// All stored state is immutable; Database and IndexStore serialize their own
/// access. A damaged helper index never prevents structural catalog queries.
struct HelperSession: Sendable {
    let configuration: HelperConfiguration
    let storageRoot: URL?
    let storageAccount: Account?
    let embedder: Embedder?
    let sourceIdentity: String?
    private let storageSourceIdentity: String?

    init(configuration: HelperConfiguration, storageRoot: URL? = nil, storageAccount: Account? = nil,
         storageSourceIdentity: String? = nil, embedder: Embedder? = nil) {
        self.configuration = configuration
        self.storageRoot = storageRoot
        self.storageAccount = storageAccount
        self.sourceIdentity = try? FileIdentity(path: configuration.databasePath).key
        self.storageSourceIdentity = storageSourceIdentity
        self.embedder = embedder
    }

    func connectedAccount() throws -> Account {
        let database = try Database(path: configuration.databasePath, readOnly: true)
        return try validate(database)
    }

    func callTool(named name: String, args: ArgReader) -> (text: String, isError: Bool) {
        withCatalog { $0.callTool(named: name, args: args) }
    }

    func withCatalog(_ operation: (Catalog) -> (text: String, isError: Bool)) -> (text: String, isError: Bool) {
        var opened = false
        do {
            let identity = try FileIdentity(path: configuration.databasePath)
            let database = try Database(path: configuration.databasePath, readOnly: true)
            opened = true
            let account = try validate(database)
            guard try identity == FileIdentity(path: configuration.databasePath) else { throw HelperFailure.changed }
            let generation = "\(identity.key):\(account.id):\(account.siteID):\(account.userID ?? -1):\(account.createdAt.timeIntervalSince1970)"
            let index: IndexStore?
            do {
                try FileManager.default.createDirectory(at: configuration.cacheDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                index = try IndexStore(path: configuration.indexPath(generation: generation))
            } catch {
                index = nil
            }
            let rootIsCurrent = account.siteID == storageAccount?.siteID && account.id == storageAccount?.id
                && account.userID == storageAccount?.userID && account.createdAt == storageAccount?.createdAt
                && identity.key == storageSourceIdentity
            let catalog = Catalog(database: database, indexStore: index, embedder: embedder,
                                  storageRoot: rootIsCurrent ? storageRoot : nil, applicationURL: configuration.applicationURL)
            let result = operation(catalog)
            guard try identity == FileIdentity(path: configuration.databasePath) else { throw HelperFailure.changed }
            let current = try validate(database)
            guard current.id == account.id, current.siteID == account.siteID,
                  current.userID == account.userID, current.createdAt == account.createdAt else {
                throw HelperFailure.changed
            }
            return result
        } catch {
            DiagnosticJournal(databasePath: configuration.databasePath)?.record(
                DiagnosticEvent(process: .helper, operation: opened ? .databaseRead : .databaseOpen,
                                outcome: .failed, failure: DiagnosticFailure(error)))
            return (Catalog.errorJSON(error as? HelperFailure ?? .unavailable), true)
        }
    }

    private func validate(_ database: Database) throws -> Account {
        let snapshot = DatabaseDiagnostics.capture(path: configuration.databasePath, siteID: nil)
        guard snapshot.failure == nil, snapshot.schemaVersion == Database.schemaVersion else { throw HelperFailure.schema }
        guard snapshot.seedComplete == true, try database.isSeedComplete() else { throw HelperFailure.incomplete }
        guard let account = try database.fetchAccounts().first(where: { $0.state.isConnected }) else { throw HelperFailure.account }
        return account
    }

    private struct FileIdentity: Equatable {
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int
        let birthNanoseconds: Int
        var key: String { "\(device):\(inode):\(birthSeconds):\(birthNanoseconds)" }

        init(path: String) throws {
            var info = stat()
            guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw HelperFailure.unavailable }
            device = info.st_dev
            inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec
            birthNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }
}
