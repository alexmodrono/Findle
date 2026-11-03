// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import AppKit
import UniformTypeIdentifiers

/// Share › Findle and the Submit to Moodle Quick Action only hand the chosen
/// files to Findle, which asks which assignment they're for. So neither
/// extension needs Findle's keychain or App Group (FX-07).
enum Handoff {
    /// Collects the shared files and opens them with Findle, then closes the request.
    @MainActor
    static func run(_ context: NSExtensionContext?) {
        guard let context else { return }
        let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                    urls.append(url)
                } else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty, let app = findleApp {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try? await NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: configuration)
            }
            context.completeRequest(returningItems: nil)
        }
    }

    /// The app that contains this extension: …/Findle.app/Contents/PlugIns/X.appex.
    private static var findleApp: URL? {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }
}

/// Nothing to show: the extension hands off at once.
class HandoffViewController: NSViewController {
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Handoff.run(extensionContext)
    }
}
