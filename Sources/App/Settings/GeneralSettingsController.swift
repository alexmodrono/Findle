import AppKit
import Combine

@MainActor
final class GeneralSettingsController: NativeFormController {
    private let state: AppState
    private let updates: UpdateController
    private let companion: FinderWindowObserver
    private let login = LoginItemController()
    private let permission = NativeUI.label("", secondary: true)
    private let error = NativeUI.label("", secondary: true)
    private var subscriptions = Set<AnyCancellable>()

    init(state: AppState, updates: UpdateController, companion: FinderWindowObserver) {
        self.state = state; self.updates = updates; self.companion = companion
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        NativeUI.section("Finder", in: stack)
        addToggle("Show companion in Findle folders", key: "finderCompanionEnabled", fallback: true)
        stack.addArrangedSubview(permission)
        stack.addArrangedSubview(ActionButton("Allow Finder Access…") { [weak self] _ in self?.companion.requestAccessibilityAccess() })
        companion.$hasAccessibilityAccess.sink { [weak self] granted in
            self?.permission.stringValue = granted ? "Finder access is enabled." : "Allow Accessibility access so Findle can identify and position itself beside your Finder window."
        }.store(in: &subscriptions)
        NativeUI.section("Sync", in: stack)
        addToggle("Sync when Findle launches", key: "syncOnLaunch", fallback: true)
        addToggle("Notify when sync completes", key: "notifyOnSyncComplete")
        let cadence = NSPopUpButton()
        let values: [(String, Double)] = [("Every 5 minutes", 5), ("Every 15 minutes", 15), ("Every 30 minutes", 30), ("Every hour", 60), ("Every 2 hours", 120), ("Manually", 0)]
        for (title, value) in values { cadence.addItem(withTitle: title); cadence.lastItem?.representedObject = value }
        let current = UserDefaults.standard.object(forKey: "syncIntervalMinutes") as? Double ?? AppState.defaultSyncIntervalMinutes
        cadence.selectItem(at: values.firstIndex { $0.1 == current } ?? 0)
        cadence.target = self
        cadence.action = #selector(changeCadence(_:))
        cadence.setAccessibilityLabel("Sync frequency")
        stack.addArrangedSubview(NativeUI.stack([NativeUI.label("Refresh"), cadence], spacing: 12, horizontal: true))
        NativeUI.section("Startup", in: stack)
        let launch = ActionButton("Open Findle at login", checkbox: true) { [weak self] button in
            guard let self else { return }
            self.login.setEnabled(button.state == .on)
            button.state = self.login.isEnabled ? .on : .off
            self.error.stringValue = self.login.lastError ?? ""
            self.error.isHidden = self.error.stringValue.isEmpty
        }
        launch.state = login.isEnabled ? .on : .off
        stack.addArrangedSubview(launch)
        stack.addArrangedSubview(error)
        error.isHidden = true
        if updates.updatesSupported {
            NativeUI.section("Updates", in: stack)
            let automatic = ActionButton("Check for updates automatically", checkbox: true) { [weak self] button in
                self?.updates.updater.automaticallyChecksForUpdates = button.state == .on
            }
            automatic.state = updates.updater.automaticallyChecksForUpdates ? .on : .off
            stack.addArrangedSubview(automatic)
            let check = ActionButton("Check for Updates…") { [weak self] _ in self?.updates.checkForUpdates() }
            updates.$canCheckForUpdates.sink { [weak check] in check?.isEnabled = $0 }.store(in: &subscriptions)
            stack.addArrangedSubview(check)
        }
        NativeUI.section("Personal files", in: stack)
        stack.addArrangedSubview(ActionButton("Show My Files") { [weak self] _ in self?.state.showPersonalFiles() })
        stack.addArrangedSubview(ActionButton("Add Shortcut in Documents") { [weak self] _ in
            guard let self else { return }
            switch self.state.ensureDocumentsShortcut(force: true) {
            case .created(let url), .alreadyExists(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failed(let detail): self.error.stringValue = detail; self.error.isHidden = false
            }
        })
    }

    private func addToggle(_ title: String, key: String, fallback: Bool = false) {
        let toggle = ActionButton(title, checkbox: true) { button in UserDefaults.standard.set(button.state == .on, forKey: key) }
        toggle.state = (UserDefaults.standard.object(forKey: key) as? Bool ?? fallback) ? .on : .off
        stack.addArrangedSubview(toggle)
    }

    @objc private func changeCadence(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Double { UserDefaults.standard.set(value, forKey: "syncIntervalMinutes") }
    }
}
