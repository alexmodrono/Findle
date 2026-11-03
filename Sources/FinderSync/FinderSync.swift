// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import Cocoa
import FinderSync
import SharedDomain

/// One thing only: a Findle button for Finder's toolbar, added with View ›
/// Customize Toolbar. Its menu lists courses, upcoming deadlines, Sync Now and
/// Settings. It adds no badges or context menus, which File Provider owns.
final class FinderSync: FIFinderSync {
    /// The links of the menu Finder last asked for, by item tag.
    private var links: [URL] = []

    override init() {
        super.init()
        // The toolbar button works in every window; no folders are watched.
        FIFinderSyncController.default().directoryURLs = []
    }

    override var toolbarItemName: String { "Findle" }
    override var toolbarItemToolTip: String { "Your courses, upcoming deadlines and sync" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "graduationcap", accessibilityDescription: "Findle") ?? NSImage()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .toolbarItemMenu else { return nil }
        let menu = NSMenu(title: "Findle")
        links = []
        for entry in ToolbarMenu.entries(for: WidgetSnapshot.read()) {
            switch entry {
            case .separator:
                menu.addItem(.separator())
            case .header(let title):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            case .action(let title, let url):
                let item = NSMenuItem(title: title, action: #selector(open(_:)), keyEquivalent: "")
                item.target = self
                item.tag = links.count
                links.append(url)
                menu.addItem(item)
            }
        }
        return menu
    }

    @objc private func open(_ sender: NSMenuItem) {
        guard links.indices.contains(sender.tag) else { return }
        NSWorkspace.shared.open(links[sender.tag])
    }
}
