import AppKit
import Airlock

@main
enum OnboardingPreviewApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = OnboardingPreviewDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class OnboardingPreviewDelegate: NSObject, NSApplicationDelegate {
    private var onboarding: AirlockWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        app.submenu?.addItem(withTitle: "Restart Preview", action: #selector(restart), keyEquivalent: "r").target = self
        app.submenu?.addItem(withTitle: "Sample Sign-In…", action: #selector(showSampleSignIn), keyEquivalent: "").target = self
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Quit Preview", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        menu.addItem(edit)
        NSApp.mainMenu = menu
        restart()
    }

    @objc private func restart() {
        onboarding?.onClose = nil
        onboarding?.close()
        // New sample state and permissions on every run. No launch arguments
        // are needed, so opening this bundle can never start the real app.
        let controller = FindleOnboarding.make(state: AppState(), observer: FinderWindowObserver(),
                                               autosavesFrame: false) { [weak self] in
            self?.showCompletion()
        }
        controller.window?.title = "Findle Onboarding Preview"
        controller.onClose = { NSApp.terminate(nil) }
        onboarding = controller
        controller.present()
    }

    @objc private func showSampleSignIn() {
        guard let window = onboarding?.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Sample sign-in"
        alert.informativeText = "Site: moodle.example.edu\nUsername: student\nPassword: preview\n\nSign-in, Finder access, and sync are simulated."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    private func showCompletion() {
        guard let window = onboarding?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Preview complete"
        alert.informativeText = "Sign-in, Finder access, and sync were simulated."
        alert.addButton(withTitle: "Restart Preview")
        alert.addButton(withTitle: "Close")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.restart() }
            else { NSApp.terminate(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onboarding?.present()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        onboarding?.onClose = nil
        onboarding?.close()
    }
}
