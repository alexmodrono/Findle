// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import AppIntents
import SwiftUI
import WidgetKit
import SharedDomain

/// Sync Findle in Control Center and the menu bar: starts a sync without
/// opening a window and shows whether Findle is syncing, up to date or needs
/// attention.
@available(macOS 26.0, *)
struct SyncControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetSnapshot.controlKind, provider: SyncStatusProvider()) { status in
            ControlWidgetButton(action: OpenURLIntent(FindleLinks.sync)) {
                Label(status.title, systemImage: status.symbolName)
            }
        }
        .displayName("Sync Findle")
        .description("Brings your Moodle courses up to date.")
    }
}

@available(macOS 26.0, *)
struct SyncStatusProvider: ControlValueProvider {
    var previewValue: WidgetSnapshot.Status { .upToDate }

    func currentValue() async throws -> WidgetSnapshot.Status {
        WidgetSnapshot.read()?.status ?? .signedOut
    }
}

extension WidgetSnapshot.Status {
    var title: String {
        switch self {
        case .upToDate: "Findle is up to date"
        case .syncing: "Findle is syncing"
        case .needsAttention: "Findle needs attention"
        case .signedOut: "Sign in to Findle"
        }
    }

    var symbolName: String {
        switch self {
        case .upToDate: "checkmark.arrow.trianglehead.counterclockwise"
        case .syncing: "arrow.triangle.2.circlepath"
        case .needsAttention: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        }
    }
}
