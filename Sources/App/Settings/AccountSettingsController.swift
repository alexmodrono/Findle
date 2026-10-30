import AppKit
import Combine
import FindlePersistence

@MainActor
final class AccountSettingsController: SettingsFormController {
    private let state: AppState
    private let reconnect: @MainActor () -> Void
    private let site = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private var signOut: ActionButton!
    private var subscription: AnyCancellable?

    init(state: AppState, reconnect: @escaping @MainActor () -> Void) {
        self.state = state; self.reconnect = reconnect
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        for field in [site, address] {
            field.isSelectable = true
            field.lineBreakMode = .byTruncatingMiddle
            field.widthAnchor.constraint(lessThanOrEqualToConstant: Self.controlWidth).isActive = true
        }
        addRow("Moodle site", site)
        addRow("Address", address)
        addRow("Status", status)
        signOut = ActionButton("Sign Out…") { [weak self] _ in
            guard let self else { return }
            NativeUI.confirm(in: self.view.window, title: "Sign out of Findle?",
                             message: "Synced course files will be removed from Finder. Your own files stay in \(PersonalFileStore.configuredFolderName).",
                             actionTitle: "Sign Out") {
                Task { await self.state.logout() }
            }
        }
        signOut.hasDestructiveAction = true
        addRow(nil, buttons([ActionButton("Reconnect…") { [weak self] _ in self?.reconnect() }, signOut])).topPadding = 12
        subscription = state.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        let current = state.currentSite
        for field in [address, status] { grid.cell(for: field)?.row?.isHidden = current == nil }
        signOut.isEnabled = current != nil
        guard let current else { site.stringValue = "Not connected"; return }
        site.stringValue = current.displayName
        address.stringValue = current.baseURL.absoluteString
        address.toolTip = current.baseURL.absoluteString
        status.stringValue = state.sessionExpired ? "Session expired. Reconnect to keep syncing." : "Connected"
        status.textColor = state.sessionExpired ? .systemRed : .labelColor
    }
}
