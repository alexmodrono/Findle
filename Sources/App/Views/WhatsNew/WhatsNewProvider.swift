// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI

/// Content for the custom "What's New" showcase shown after an update.
struct WhatsNewRelease {
    let version: String
    let headline: String
    let subheadline: String
    let sections: [Section]

    struct Section: Identifiable {
        let id = UUID()
        let icon: String
        let tint: Color
        let title: String
        let body: String
        /// A featured section gets the prominent gradient treatment and, for the
        /// MCP, the "Connect to Claude" actions.
        var style: Style = .standard

        enum Style {
            case standard
            case connectToClaude
        }
    }
}

extension WhatsNewRelease {
    /// The release currently advertised. Bump `version` to re-show the sheet.
    static let current = WhatsNewRelease(
        version: "0.2.0",
        headline: "A fresh look — and an AI that knows your courses",
        subheadline: "Findle 0.2.0",
        sections: [
            Section(
                icon: "sparkles",
                tint: .pink,
                title: "Connect your coursework to Claude",
                body: "Findle now ships a built-in assistant bridge. Let Claude search across all your courses, read your notes and slides, summarise theory, and track deadlines and grades — grounded in your own files, with nothing to upload.",
                style: .connectToClaude
            ),
            Section(
                icon: "square.grid.2x2",
                tint: .blue,
                title: "A course gallery",
                body: "Your courses now appear as a bookshelf of covers — pulled from Moodle when available — so you can jump straight to what you need."
            ),
            Section(
                icon: "rectangle.3.group",
                tint: .purple,
                title: "Redesigned course view",
                body: "An elastic cover header, file and download counts at a glance, a browsable contents list, and an inline editor for the icon, name, and tags."
            ),
            Section(
                icon: "calendar.badge.clock",
                tint: .orange,
                title: "Deadlines & grades",
                body: "Findle now tracks assignment due dates, submission status, grades, and quiz attempts — ready for the assistant to reason over."
            )
        ]
    )
}
