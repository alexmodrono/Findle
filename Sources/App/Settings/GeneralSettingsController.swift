import AppKit
import Combine

@MainActor
final class GeneralSettingsController: SettingsFormController {
    private let state: AppState
    private let updates: UpdateController
    private let companion: FinderWindowObserver
    private let login = LoginItemController()
    private let permission = NSTextField(wrappingLabelWithString: "")
    private let loginError = NSTextField(wrappingLabelWithString: "")
    private let shortcutError = NSTextField(wrappingLabelWithString: "")
    private var subscriptions = Set<AnyCancellable>()

    init(state: AppState, updates: UpdateController, companion: FinderWindowObserver) {
        self.state = state; self.updates = updates; self.companion = companion
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        addRow("Finder", toggle("Show companion beside Findle folders", key: "finderCompanionEnabled", fallback: true))
        let allow = ActionButton("Allow Finder Access…") { [weak self] _ in self?.companion.requestAccessibilityAccess() }
        let allowRow = addRow(nil, allow)
        let permissionRow = addNote(permission)
        permission.stringValue = "Findle needs Accessibility access to place the companion beside your Finder window."
        companion.$hasAccessibilityAccess.sink { granted in
            allowRow.isHidden = granted
            permissionRow.isHidden = granted
        }.store(in: &subscriptions)

        addSeparator()
        addRow("Sync", toggle("Sync when Findle launches", key: "syncOnLaunch", fallback: true))
        addRow(nil, toggle("Notify when sync completes", key: "notifyOnSyncComplete"))
        let cadence = NSPopUpButton()
        let values: [(String, Double)] = [("Every 5 minutes", 5), ("Every 15 minutes", 15), ("Every 30 minutes", 30), ("Every hour", 60), ("Every 2 hours", 120), ("Manually", 0)]
        for (title, value) in values { cadence.addItem(withTitle: title); cadence.lastItem?.representedObject = value }
        let current = UserDefaults.standard.object(forKey: "syncIntervalMinutes") as? Double ?? AppState.defaultSyncIntervalMinutes
        cadence.selectItem(at: values.firstIndex { $0.1 == current } ?? 0)
        cadence.target = self
        cadence.action = #selector(changeCadence(_:))
        cadence.setAccessibilityLabel("Sync frequency")
        addRow("Frequency", cadence)

        addSeparator()
        let launch = ActionButton("Open Findle at login", checkbox: true) { [weak self] button in
            guard let self else { return }
            self.login.setEnabled(button.state == .on)
            button.state = self.login.isEnabled ? .on : .off
            self.show(self.login.lastError, in: self.loginError)
        }
        launch.state = login.isEnabled ? .on : .off
        addRow("Startup", launch)
        addError(loginError)
        if updates.updatesSupported {
            let automatic = ActionButton("Check for updates automatically", checkbox: true) { [weak self] button in
                self?.updates.updater.automaticallyChecksForUpdates = button.state == .on
            }
            automatic.state = updates.updater.automaticallyChecksForUpdates ? .on : .off
            addRow("Updates", automatic).topPadding = 8
            let check = ActionButton("Check for Updates…") { [weak self] _ in self?.updates.checkForUpdates() }
            updates.$canCheckForUpdates.sink { [weak check] in check?.isEnabled = $0 }.store(in: &subscriptions)
            addRow(nil, check)
        }

        addSeparator()
        addRow("Personal files", buttons([
            ActionButton("Show My Files") { [weak self] _ in self?.state.showPersonalFiles() },
            ActionButton("Add Shortcut in Documents") { [weak self] _ in
                guard let self else { return }
                switch self.state.ensureDocumentsShortcut(force: true) {
                case .created(let url), .alreadyExists(let url):
                    self.show(nil, in: self.shortcutError)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failed(let detail): self.show(detail, in: self.shortcutError)
                }
            }
        ]))
        addError(shortcutError)
    }

    private func toggle(_ title: String, key: String, fallback: Bool = false) -> ActionButton {
        let toggle = ActionButton(title, checkbox: true) { button in UserDefaults.standard.set(button.state == .on, forKey: key) }
        toggle.state = (UserDefaults.standard.object(forKey: key) as? Bool ?? fallback) ? .on : .off
        return toggle
    }

    private func addError(_ field: NSTextField) {
        addNote(field).isHidden = true
        field.textColor = .systemRed
    }

    private func show(_ message: String?, in field: NSTextField) {
        field.stringValue = message ?? ""
        grid.cell(for: field)?.row?.isHidden = message?.isEmpty ?? true
    }

    @objc private func changeCadence(_ sender: NSPopUpButton) {
        if let value = sender.selectedItem?.representedObject as? Double { UserDefaults.standard.set(value, forKey: "syncIntervalMinutes") }
    }
}
