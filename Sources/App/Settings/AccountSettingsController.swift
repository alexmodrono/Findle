import AppKit
import Combine
import FindlePersistence

@MainActor
final class AccountSettingsController: NativeFormController {
    private let state: AppState
    private let reconnect: @MainActor () -> Void
    private let details = NativeUI.label("")
    private var subscription: AnyCancellable?

    init(state: AppState, reconnect: @escaping @MainActor () -> Void) {
        self.state = state; self.reconnect = reconnect
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        NativeUI.section("Moodle account", in: stack)
        details.isSelectable = true
        stack.addArrangedSubview(details)
        stack.addArrangedSubview(ActionButton("Reconnect…") { [weak self] _ in self?.reconnect() })
        stack.addArrangedSubview(ActionButton("Sign Out…") { [weak self] _ in
            guard let self else { return }
            NativeUI.confirm(in: self.view.window, title: "Sign out of Findle?",
                             message: "Synced course files will be removed from Finder. Your own files stay in \(PersonalFileStore.configuredFolderName).",
                             actionTitle: "Sign Out") {
                Task { await self.state.logout() }
            }
        })
        subscription = state.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        guard let site = state.currentSite else { details.stringValue = "No account connected."; return }
        details.stringValue = "\(site.displayName)\n\(site.baseURL.absoluteString)\n\(state.sessionExpired ? "Session expired" : "Connected")"
    }
}
