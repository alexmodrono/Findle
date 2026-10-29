import Foundation
import CryptoKit

/// The CLI's Bundle.main is not the owning app. Resolve the enclosing bundle
/// explicitly, and never fall back to another database when a configured path
/// is unavailable (a provider reset can retire that path).
struct HelperConfiguration: Sendable {
    enum Channel: String, Sendable {
        case release, nightly

        var bundleIdentifier: String { "es.amodrono.findle" + (self == .nightly ? ".nightly" : "") }
        var port: UInt16 { self == .nightly ? 8766 : 8765 }
    }

    let channel: Channel
    let applicationURL: URL?
    let databasePath: String
    let cacheDirectory: URL
    let http: HTTPOptions?

    init(arguments: [String] = CommandLine.arguments,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        func value(_ flag: String) throws -> String? {
            let indices = arguments.indices.filter { arguments[$0] == flag }
            guard indices.count <= 1 else { throw HelperFailure.configuration }
            guard let index = indices.first else { return nil }
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"),
                  !arguments[index + 1].isEmpty else { throw HelperFailure.configuration }
            return arguments[index + 1]
        }

        var parent = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        var app: URL?
        while parent.path != "/" {
            if parent.pathExtension == "app" { app = parent; break }
            parent.deleteLastPathComponent()
        }
        applicationURL = app
        let bundleID = app.flatMap { Bundle(url: $0)?.bundleIdentifier }
        let bundledChannel: Channel?
        switch bundleID {
        case Channel.release.bundleIdentifier: bundledChannel = .release
        case Channel.nightly.bundleIdentifier: bundledChannel = .nightly
        case nil: bundledChannel = nil
        default: throw HelperFailure.configuration
        }
        let requested = try value("--channel") ?? environment["FINDLE_CHANNEL"]
        let requestedChannel = requested.flatMap(Channel.init(rawValue:))
        if requested != nil, requestedChannel == nil { throw HelperFailure.configuration }
        if let bundledChannel, let requestedChannel, bundledChannel != requestedChannel {
            throw HelperFailure.configuration
        }
        channel = bundledChannel ?? requestedChannel ?? .release

        let explicitPath = try environment["FINDLE_DB_PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? value("--db-path")
        let defaultPath = homeDirectory.appendingPathComponent(
            "Library/Group Containers/group.\(channel.bundleIdentifier)/Application Support/Findle/findle.db"
        ).path
        databasePath = explicitPath ?? defaultPath
        guard databasePath.hasPrefix("/"), !databasePath.contains("\0") else { throw HelperFailure.configuration }
        cacheDirectory = homeDirectory.appendingPathComponent("Library/Caches/FindleMCP/\(channel.rawValue)", isDirectory: true)
        http = try HTTPOptions.parse(arguments: arguments, environment: environment, defaultPort: channel.port)
    }

    /// Namespace caches by both the installation and the source generation.
    /// Hashing prevents paths/account identifiers becoming cache filenames.
    func indexPath(generation: String) -> String {
        let key = Data((databasePath + "\0" + generation).utf8)
        let digest = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(digest).appendingPathExtension("db").path
    }
}

struct HTTPOptions: Sendable {
    let port: UInt16
    let token: String

    static func parse(arguments: [String], environment: [String: String], defaultPort: UInt16) throws -> HTTPOptions? {
        guard let index = arguments.firstIndex(of: "--http") else { return nil }
        guard arguments.filter({ $0 == "--http" }).count == 1 else { throw HelperFailure.configuration }
        var port = defaultPort
        if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
            let raw = arguments[index + 1].hasPrefix(":") ? String(arguments[index + 1].dropFirst()) : arguments[index + 1]
            guard let requested = UInt16(raw), requested > 0 else { throw HelperFailure.configuration }
            port = requested
        }
        var token = environment["FINDLE_MCP_TOKEN"]
        if let index = arguments.firstIndex(of: "--token") {
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw HelperFailure.configuration }
            token = arguments[index + 1]
        }
        guard let token, !token.isEmpty else { throw HelperFailure.authentication }
        return HTTPOptions(port: port, token: token)
    }
}

enum HelperFailure: Error, LocalizedError {
    case configuration, authentication, unavailable, changed, schema, incomplete, account

    var errorDescription: String? {
        switch self {
        case .configuration: "Invalid helper configuration. Check the channel, database path and HTTP port."
        case .authentication: "HTTP mode requires a bearer token."
        case .unavailable: "The configured database is unavailable. Reconnect the assistant from Findle."
        case .changed: "The database changed during this request. Retry; reconnect the assistant if the provider was reset."
        case .schema: "The database schema is unavailable or incompatible. Finish updating Findle and reconnect the assistant."
        case .incomplete: "The database is being prepared or reset. Retry after Findle finishes syncing."
        case .account: "No connected account is available. Sign in to this Findle installation first."
        }
    }
}
