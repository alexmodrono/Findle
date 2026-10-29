import AppKit

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (@MainActor () -> Void)?

    init(state: AppState, updates: UpdateController, companion: FinderWindowObserver, autosavesFrame: Bool = true,
         reconnect: @escaping @MainActor () -> Void) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let pages: [(String, String, NSViewController)] = [
            ("Courses", "folder", CoursesSettingsController(state: state)),
            ("General", "gearshape", GeneralSettingsController(state: state, updates: updates, companion: companion)),
            ("Account", "person.crop.circle", AccountSettingsController(state: state, reconnect: reconnect)),
            ("Assistants", "bubble.left.and.bubble.right", AssistantSettingsController(state: state)),
            ("Diagnostics", "stethoscope", DiagnosticsController(state: state))
        ]
        for (title, symbol, controller) in pages {
            controller.title = title
            let item = NSTabViewItem(viewController: controller)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Findle Settings"
        window.minSize = NSSize(width: 640, height: 480)
        window.contentViewController = tabs
        window.setContentSize(NSSize(width: 760, height: 570))
        window.isReleasedWhenClosed = false
        if autosavesFrame { window.setFrameAutosaveName("Findle.Settings") }
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}
