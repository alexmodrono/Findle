// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import AppKit
import FileProvider
import FileProviderUI
import SharedDomain
import SwiftUI

/// Findle's sheet in Finder. When the Moodle session expires, Finder shows it
/// instead of only reporting the location as signed out. Reconnecting opens
/// Findle's sign-in; once the app restores the session the sheet closes and
/// Finder retries. Cancelling leaves the error in place.
final class ReconnectViewController: FPUIActionExtensionViewController {
    private var sessionObserver: DarwinNotification.Token?
    private let model = ReconnectModel()

    override func loadView() {
        let hosting = NSHostingView(rootView: ReconnectView(model: model,
                                                            reconnect: { [weak self] in self?.reconnect() },
                                                            cancel: { [weak self] in self?.cancel() }))
        hosting.frame = NSRect(x: 0, y: 0, width: 420, height: 220)
        view = hosting
    }

    override func prepare(forError error: Error) {
        let nsError = error as NSError
        guard nsError.domain == NSFileProviderErrorDomain, nsError.code == NSFileProviderError.notAuthenticated.rawValue else {
            cancel()
            return
        }
        guard let domain = extensionContext.domainIdentifier else { return }
        Task { @MainActor [model] in
            if let name = await Self.domainDisplayName(domain) { model.institution = name }
        }
    }

    private func reconnect() {
        model.waiting = true
        sessionObserver = DarwinNotification.addObserver(for: BundleIdentifiers.sessionRestoredNotification) { [weak self] in
            Task { @MainActor in self?.extensionContext.completeRequest() }
        }
        NSWorkspace.shared.open(FindleLinks.reconnect)
    }

    private func cancel() {
        sessionObserver = nil
        extensionContext.cancelRequest(withError: NSError(domain: FPUIErrorDomain, code: Int(FPUIExtensionErrorCode.userCancelled.rawValue)))
    }

    /// The domain's name in Finder is the Moodle site's name.
    private static func domainDisplayName(_ identifier: NSFileProviderDomainIdentifier) async -> String? {
        guard let domains = try? await NSFileProviderManager.domains() else { return nil }
        return domains.first { $0.identifier == identifier }?.displayName
    }
}

@MainActor
@Observable
final class ReconnectModel {
    var institution = "your Moodle site"
    var waiting = false
}

struct ReconnectView: View {
    let model: ReconnectModel
    let reconnect: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reconnect to \(model.institution)").font(.headline)
                    Text("Your Moodle session expired. Sign in again to keep your courses up to date in Finder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in Findle…").font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(model.waiting ? "Open Findle Again" : "Reconnect…", action: reconnect)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
