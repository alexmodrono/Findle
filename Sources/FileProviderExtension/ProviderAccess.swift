import FileProvider
import SharedDomain
import FindlePersistence

enum ProviderAccess {
    /// Missing/incomplete storage and failed Keychain reads are retryable.
    /// Only a successfully read, absent account/token indicates sign-out.
    static func enumerationDatabase(
        _ database: Database?,
        siteID: String?,
        tokenLookup: (String) throws -> String?
    ) throws -> Database {
        guard let database, let siteID, !siteID.isEmpty else { throw NSFileProviderError(.serverUnreachable) }
        let accounts: [Account]
        do {
            guard try database.isSeedComplete() else { throw NSFileProviderError(.serverUnreachable) }
            accounts = try database.fetchAccounts()
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .databaseRead, outcome: .failed, failure: DiagnosticFailure(error)))
            throw NSFileProviderError(.serverUnreachable)
        }
        guard let account = accounts.last(where: { $0.siteID == siteID && $0.state.isConnected }) else {
            throw NSFileProviderError(.notAuthenticated)
        }
        let token: String?
        do {
            token = try tokenLookup(account.id)
        } catch {
            DiagnosticJournal(databasePath: database.filePath)?.record(.init(
                process: .fileProvider, operation: .authentication, outcome: .failed, failure: DiagnosticFailure(error)))
            throw NSFileProviderError(.serverUnreachable)
        }
        guard let token, !token.isEmpty else { throw NSFileProviderError(.notAuthenticated) }
        return database
    }

    static func enumerationError(_ error: Error) -> Error {
        let error = error as NSError
        return error.domain == NSFileProviderErrorDomain ? error : NSFileProviderError(.serverUnreachable)
    }
}
