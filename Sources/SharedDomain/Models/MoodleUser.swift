// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Foundation

/// An authenticated Moodle user.
public struct MoodleUser: Sendable, Codable, Equatable, Identifiable {
    public let id: Int
    public let username: String
    public let fullName: String
    public let email: String?
    public let profileImageURL: URL?
    public let siteID: String

    public init(
        id: Int,
        username: String,
        fullName: String,
        email: String? = nil,
        profileImageURL: URL? = nil,
        siteID: String
    ) {
        self.id = id
        self.username = username
        self.fullName = fullName
        self.email = email
        self.profileImageURL = profileImageURL
        self.siteID = siteID
    }
}
