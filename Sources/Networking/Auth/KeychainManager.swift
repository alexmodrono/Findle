// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation
import Security
import OSLog
import SharedDomain

/// Manages secure credential storage in the macOS Keychain.
public final class KeychainManager: Sendable {
    public static let shared = KeychainManager()

    private let logger = Logger(subsystem: "es.amodrono.findle.networking", category: "Keychain")
    private let service = BundleIdentifiers.keychainService

    private init() {}

    /// Store a token for a given account.
    public func storeToken(_ token: String, forAccount account: String) throws {
        let data = Data(token.utf8)

        // Try update-in-place first so the credential isn't briefly absent
        // between a delete and an add — if the process is killed mid-write
        // the user would silently be logged out. SecItemUpdate is atomic
        // and also normalises any accessibility-class mismatch from older
        // builds (where the item may have been stored with WhenUnlocked).
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(lookupQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            logger.error("Keychain update failed: \(updateStatus)")
            throw KeychainError.storeFailed(status: updateStatus)
        }

        // Item doesn't exist yet — add it.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logger.error("Keychain add failed: \(addStatus)")
            throw KeychainError.storeFailed(status: addStatus)
        }
    }

    /// Retrieve a token for a given account.
    public func retrieveToken(forAccount account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            logger.error("Failed to retrieve token: \(status)")
            throw KeychainError.retrieveFailed(status: status)
        }

        return String(data: data, encoding: .utf8)
    }

    /// Delete a token for a given account.
    public func deleteToken(forAccount account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Failed to delete token: \(status)")
            throw KeychainError.deleteFailed(status: status)
        }
    }

    /// Delete all tokens for this app.
    public func deleteAllTokens() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }
}

public enum KeychainError: Error, LocalizedError {
    case storeFailed(status: OSStatus)
    case retrieveFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .storeFailed(let status):
            return "Failed to store credentials (error \(status))."
        case .retrieveFailed(let status):
            return "Failed to retrieve credentials (error \(status))."
        case .deleteFailed(let status):
            return "Failed to delete credentials (error \(status))."
        }
    }
}
