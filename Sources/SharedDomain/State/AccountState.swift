// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// The lifecycle state of a Moodle account/connection.
public enum AccountState: Sendable, Codable, Equatable {
    case disconnected
    case validating
    case authenticated(userID: Int)
    case expired
    case reauthenticating
    case incompatible(reason: String)
    case error(message: String)

    public var isConnected: Bool {
        switch self {
        case .authenticated:
            return true
        default:
            return false
        }
    }

    public var needsReauth: Bool {
        switch self {
        case .expired, .reauthenticating:
            return true
        default:
            return false
        }
    }
}

/// Persistent account record tying together site, user, and state.
public struct Account: Sendable, Codable, Equatable, Identifiable {
    public let id: String
    public let siteID: String
    public var userID: Int?
    public var state: AccountState
    public var lastSyncDate: Date?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        siteID: String,
        userID: Int? = nil,
        state: AccountState = .disconnected,
        lastSyncDate: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.siteID = siteID
        self.userID = userID
        self.state = state
        self.lastSyncDate = lastSyncDate
        self.createdAt = createdAt
    }
}
