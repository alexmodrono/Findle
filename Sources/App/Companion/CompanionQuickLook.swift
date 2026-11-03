// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import AppKit
import Quartz

/// Space in the companion's outline previews the row's file, as in Finder.
/// A file that isn't downloaded yet downloads as Quick Look reads it.
@MainActor
final class CompanionQuickLook: NSObject, QLPreviewPanelDataSource {
    static let shared = CompanionQuickLook()
    private var url: URL?
    private var accessing = false

    func show(_ url: URL) {
        stopAccessing()
        // File Provider URLs are security-scoped; keep access while previewing.
        accessing = url.startAccessingSecurityScopedResource()
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func stopAccessing() {
        if accessing { url?.stopAccessingSecurityScopedResource() }
        accessing = false
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { url == nil ? 0 : 1 }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { url as NSURL? }
    }
}
