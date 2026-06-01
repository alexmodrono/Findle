// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import AppKit
import OSLog
import Security

/// Registers Findle's bundled MCP server with Claude Desktop and Claude Code by
/// merging a `findle` entry into their JSON config files.
///
/// The app is sandboxed, so two things matter: writes to these well-known paths
/// are permitted by a temporary-exception home-relative-path entitlement, and
/// the *real* home directory must be used (the sandbox otherwise redirects `~`
/// into the app container). If the write is blocked anyway, it falls back to
/// copying a ready-to-paste snippet to the clipboard and revealing the config.
@MainActor
enum ClaudeIntegration {
    private static let logger = Logger(subsystem: "es.amodrono.foodle", category: "ClaudeIntegration")

    enum Target: CaseIterable, Hashable {
        case desktop
        case code

        var displayName: String { self == .desktop ? "Claude Desktop" : "Claude Code" }

        var configURL: URL {
            switch self {
            case .desktop:
                return realHome.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
            case .code:
                return realHome.appendingPathComponent(".claude.json")
            }
        }

        /// Whether the target appears to be installed (so the UI can hide options
        /// that would otherwise just produce an orphan config).
        var isLikelyInstalled: Bool {
            switch self {
            case .desktop:
                return FileManager.default.fileExists(atPath: "/Applications/Claude.app")
            case .code:
                return FileManager.default.fileExists(atPath: configURL.path)
            }
        }
    }

    enum Outcome {
        case installed
        case copiedToClipboard
    }

    /// The user's real home, bypassing the sandbox container redirection.
    nonisolated static var realHome: URL {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Path of the MCP helper bundled inside the app.
    static var helperPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "FindleMCP")?.path
    }

    /// A random hex token for the HTTP transport's bearer auth.
    static func generateToken(bytes count: Int = 24) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            bytes = (0..<count).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The Terminal command that runs the bundled MCP helper in HTTP mode, ready
    /// to copy/paste — pinned to the app's actual database path and bearer token.
    static func chatGPTCommand(token: String, port: Int, databasePath: String?) -> String {
        var parts = ["FINDLE_MCP_TOKEN=\"\(token)\""]
        if let databasePath { parts.append("FINDLE_DB_PATH=\"\(databasePath)\"") }
        parts.append("\"\(helperPath ?? "FindleMCP")\"")
        parts.append("--http \(port)")
        return parts.joined(separator: " ")
    }

    /// Whether a `findle` MCP server is already registered with `target`. Returns
    /// `false` if the config is missing or unreadable.
    static func isInstalled(_ target: Target) -> Bool {
        guard let data = try? Data(contentsOf: target.configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else {
            return false
        }
        return servers["findle"] != nil
    }

    /// Register the bundled MCP server with `target`, passing the app's actual
    /// database path so the helper reads the right App Group (release vs nightly).
    @discardableResult
    static func install(_ target: Target, databasePath: String?) -> Outcome {
        let entry = serverEntry(databasePath: databasePath)
        do {
            try merge(entry: entry, into: target.configURL)
            logger.info("Registered MCP server with \(target.displayName, privacy: .public)")
            return .installed
        } catch {
            logger.warning("Direct write to \(target.displayName, privacy: .public) failed (\(error.localizedDescription, privacy: .public)); falling back to clipboard")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snippet(entry: entry), forType: .string)
            if FileManager.default.fileExists(atPath: target.configURL.path) {
                NSWorkspace.shared.activateFileViewerSelecting([target.configURL])
            }
            return .copiedToClipboard
        }
    }

    // MARK: - Internals

    private static func serverEntry(databasePath: String?) -> [String: Any] {
        var entry: [String: Any] = ["command": helperPath ?? "FindleMCP"]
        if let databasePath { entry["env"] = ["FINDLE_DB_PATH": databasePath] }
        return entry
    }

    /// Read the existing config (if any), set `mcpServers.findle`, and write back
    /// atomically — preserving every other key. Never overwrites a config that
    /// exists but can't be parsed.
    private static func merge(entry: [String: Any], into url: URL) throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            root = object
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers["findle"] = entry
        root["mcpServers"] = servers

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    /// A standalone `mcpServers` snippet for the clipboard fallback.
    private static func snippet(entry: [String: Any]) -> String {
        let wrapper: [String: Any] = ["mcpServers": ["findle": entry]]
        let data = (try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
