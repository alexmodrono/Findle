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

    private let logger = Logger(subsystem: "es.amodrono.foodle.networking", category: "Keychain")
    private let service = BundleIdentifiers.keychainService

    private init() {}

    /// Store a token for a given account.
    ///
    /// Writes to the data-protection keychain so the token is shared with the
    /// File Provider extension through their common `keychain-access-group`
    /// entitlement. Access there is granted by entitlement rather than a
    /// per-binary ACL, so it survives the app being re-signed (e.g. by a Sparkle
    /// update) — unlike the file-based keychain, where a re-signed extension
    /// silently loses read access and the domain shows as "signed out".
    public func storeToken(_ token: String, forAccount account: String) throws {
        let data = Data(token.utf8)

        // Try update-in-place first so the credential isn't briefly absent
        // between a delete and an add — if the process is killed mid-write
        // the user would silently be logged out. SecItemUpdate is atomic
        // and also normalises any accessibility-class mismatch from older
        // builds (where the item may have been stored with WhenUnlocked).
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query(account: account) as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            try? deleteLegacyToken(account: account)
            return
        }
        guard updateStatus == errSecItemNotFound else {
            logger.error("Keychain update failed: \(updateStatus)")
            throw KeychainError.storeFailed(status: updateStatus)
        }

        // Item doesn't exist yet — add it.
        var addQuery = query(account: account)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            logger.error("Keychain add failed: \(addStatus)")
            throw KeychainError.storeFailed(status: addStatus)
        }
        try? deleteLegacyToken(account: account)
    }

    /// Retrieve a token for a given account.
    public func retrieveToken(forAccount account: String) throws -> String? {
        // Preferred: the shared data-protection keychain.
        if let token = try copyToken(account: account, dataProtection: true) {
            return token
        }

        // Legacy: older builds stored the token in the file-based login keychain,
        // which the File Provider extension cannot read after the app is
        // re-signed. Migrate any such token into the shared keychain so the
        // extension regains access without the user signing in again.
        if let legacy = (try? copyToken(account: account, dataProtection: false)) ?? nil {
            try? storeToken(legacy, forAccount: account)
            return legacy
        }

        return nil
    }

    /// Delete a token for a given account.
    public func deleteToken(forAccount account: String) throws {
        let status = SecItemDelete(query(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("Failed to delete token: \(status)")
            throw KeychainError.deleteFailed(status: status)
        }
        try? deleteLegacyToken(account: account)
    }

    /// Delete all tokens for this app, in both the shared and legacy keychains.
    public func deleteAllTokens() throws {
        for dataProtection in [true, false] {
            var deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service
            ]
            deleteQuery[kSecUseDataProtectionKeychain as String] = dataProtection
            let status = SecItemDelete(deleteQuery as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.deleteFailed(status: status)
            }
        }
    }

    // MARK: - Keychain query helpers

    /// Base query against the data-protection keychain. Items land in the app's
    /// default access group — the sole `keychain-access-groups` entitlement entry
    /// shared by the app and the extension — so no explicit access group is set.
    private func query(account: String?) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true
        ]
        if let account {
            q[kSecAttrAccount as String] = account
        }
        return q
    }

    private func copyToken(account: String, dataProtection: Bool) throws -> String? {
        let copyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: dataProtection,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(copyQuery as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            logger.error("Failed to retrieve token: \(status)")
            throw KeychainError.retrieveFailed(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the token from the legacy file-based keychain used by older builds.
    private func deleteLegacyToken(account: String) throws {
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false
        ]
        let status = SecItemDelete(legacyQuery as CFDictionary)
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
