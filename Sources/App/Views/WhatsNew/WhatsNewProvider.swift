// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import WhatsNewKit

/// Central registry of all What's New entries shown after app updates.
enum WhatsNewProvider {
    nonisolated(unsafe) static let collection: WhatsNewCollection = [
        WhatsNew(
            version: "0.1.2",
            title: "What's New in Findle",
            features: [
                WhatsNew.Feature(
                    image: .init(
                        systemName: "folder.fill",
                        foregroundColor: .accentColor
                    ),
                    title: "Your Courses in Finder",
                    subtitle: "Browse and open Moodle files directly from the Finder sidebar — no browser needed."
                ),
                WhatsNew.Feature(
                    image: .init(
                        systemName: "arrow.down.circle.fill",
                        foregroundColor: .green
                    ),
                    title: "On-Demand Downloads",
                    subtitle: "Files download only when you open them and can be evicted to save disk space."
                ),
                WhatsNew.Feature(
                    image: .init(
                        systemName: "lock.shield.fill",
                        foregroundColor: .orange
                    ),
                    title: "SSO & Direct Login",
                    subtitle: "Sign in with your university's SSO provider or with username and password."
                ),
                WhatsNew.Feature(
                    image: .init(
                        systemName: "doc.badge.plus",
                        foregroundColor: .purple
                    ),
                    title: "Local Files",
                    subtitle: "Create your own notes and files alongside course content — they stay local and never sync."
                )
            ],
            primaryAction: WhatsNew.PrimaryAction(
                title: "Continue",
                backgroundColor: .accentColor,
                foregroundColor: .white
            )
        )
    ]
}
