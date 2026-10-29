import AppKit
import Airlock
import Carbon
import Combine
import CoreSpotlight

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var state = AppState()
    private lazy var updates = UpdateController()
    private var companion: CompanionWindowController?
    private var settings: SettingsWindowController?
    private var onboarding: AirlockWindowController?
    private var subscription: AnyCancellable?
    #if DEBUG
    private var interfacePreview: InterfacePreview?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--ui-preview"),
           ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
            do {
                let preview = try InterfacePreview(mode: ProcessInfo.processInfo.arguments[index + 1])
                interfacePreview = preview
                preview.run()
            } catch {
                print("Interface preview failed: \(error)")
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        LegacySettingsMigration.run()
        UserDefaults.standard.register(defaults: ["finderCompanionEnabled": true])
        configureMenu()
        let companion = CompanionWindowController(state: state) { [weak self] in self?.showSettings() }
        self.companion = companion
        companion.start()
        subscription = state.$currentScreen.removeDuplicates().dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in self?.screenChanged() }
        }
        if state.currentScreen == .onboarding {
            showOnboarding()
        } else {
            let event = NSAppleEventManager.shared().currentAppleEvent
            let loginLaunch = event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            let urlLaunch = (event?.eventID ?? 0) == AEEventID(kAEGetURL)
            if !loginLaunch && !urlLaunch && !ProcessInfo.processInfo.arguments.contains("--background") { showSettings() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if state.currentScreen == .onboarding { showOnboarding() } else { showSettings() }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        #if DEBUG
        if interfacePreview != nil { return }
        #endif
        state.resolveFileProviderAuthIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        #if DEBUG
        if interfacePreview != nil { return }
        #endif
        companion?.stop()
        onboarding?.navigator.cancelPendingAction()
        state.stopPersonalFilesWatcher()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "findle" && url.host == "sync" {
            let courseID = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "course" }?.value.flatMap(Int.init)
            Task {
                if state.courses.isEmpty { await state.loadCourses() }
                if let courseID, let course = state.courses.first(where: { $0.id == courseID }) {
                    _ = await state.syncCourse(course)
                } else { await state.syncAll() }
            }
        }
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType else { return false }
        state.handleSpotlightActivity(userActivity)
        return true
    }

    private func screenChanged() {
        if state.currentScreen == .onboarding {
            settings?.close()
            showOnboarding()
        } else {
            onboarding?.close()
            onboarding = nil
            updateActivationPolicy()
        }
    }

    private func showOnboarding() {
        guard let companion else { return }
        NSApp.setActivationPolicy(.regular)
        if let onboarding { onboarding.present(); return }
        let controller = FindleOnboarding.make(state: state, observer: companion.observer) { [weak self] in
            self?.state.finishOnboarding()
        }
        controller.onClose = { [weak self] in
            guard let self else { return }
            self.onboarding = nil
            if self.state.currentScreen == .onboarding, self.state.currentToken != nil {
                self.state.currentScreen = .workspace
            }
            self.updateActivationPolicy()
        }
        onboarding = controller
        controller.present()
    }

    @objc private func showSettings() {
        guard state.currentScreen == .workspace, let companion else { showOnboarding(); return }
        if settings == nil {
            let controller = SettingsWindowController(state: state, updates: updates, companion: companion.observer) { [weak self] in
                self?.showSetup()
            }
            controller.onClose = { [weak self] in self?.updateActivationPolicy() }
            settings = controller
        }
        settings?.present()
    }

    @objc private func showSetup() {
        settings?.close()
        state.currentScreen = .onboarding
        showOnboarding()
    }

    private func updateActivationPolicy() {
        // The companion stays an accessory; only configuration windows need a Dock item.
        Task { @MainActor in
            let hasWindow = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible && !$0.isMiniaturized }
            NSApp.setActivationPolicy(hasWindow ? .regular : .accessory)
        }
    }

    private func configureMenu() {
        let menu = NSMenu()
        let app = NSMenuItem()
        app.submenu = NSMenu()
        let about = NSMenuItem(title: "About Findle", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.submenu?.addItem(about)
        app.submenu?.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        app.submenu?.addItem(settings)
        let setup = NSMenuItem(title: "Set Up Findle…", action: #selector(showSetup), keyEquivalent: "")
        setup.target = self
        app.submenu?.addItem(setup)
        let open = NSMenuItem(title: "Open Findle in Finder", action: #selector(openFinder), keyEquivalent: "o")
        open.target = self
        app.submenu?.addItem(open)
        app.submenu?.addItem(.separator())
        app.submenu?.addItem(withTitle: "Quit Findle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(app)
        let edit = NSMenuItem()
        edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(edit)
        NSApp.mainMenu = menu
    }

    @objc private func openFinder() { Task { await state.openFileProviderInFinder() } }
}
