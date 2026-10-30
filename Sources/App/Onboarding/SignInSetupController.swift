import AppKit
import AuthenticationServices
import FindleNetworking
import SharedDomain

@MainActor
final class SignInSetupController: SetupStepController, NSTextFieldDelegate, ASWebAuthenticationPresentationContextProviding {
    private let username = NSTextField()
    private let password = NSSecureTextField()
    private let institution = SetupContextView(image: SetupAppearance.symbol("globe"), title: "", detail: "")
    private let signInMethod = NativeUI.label("", secondary: true, size: 13)
    private var credentials: SetupFormGroup?
    private var embedded: EmbeddedAuthCoordinator?
    private var browserContainer: NSView?
    private var signInAttempt: UUID?

    override func buildContent() {
        addFullWidth(SetupStepHeader(title: "Sign in", detail: "Use your university account."))
        addFullWidth(SetupFormGroup([institution]))
        username.placeholderString = "Username"
        username.setAccessibilityLabel("Moodle username")
        username.delegate = self
        password.placeholderString = "Password"
        password.setAccessibilityLabel("Moodle password")
        password.delegate = self
        SetupAppearance.configure(username)
        SetupAppearance.configure(password)
        let credentials = SetupFormGroup([username, password])
        self.credentials = credentials
        addFullWidth(credentials)
        addFullWidth(signInMethod)
    }

    override func prepareForPresentation() {
        guard let site = session.site else { navigator?.setContinueEnabled(false); return }
        institution.update(title: site.displayName, detail: site.baseURL.host ?? site.baseURL.absoluteString)
        signInMethod.stringValue = site.capabilities.loginType == .browser
            ? "Your university’s sign-in opens in your browser."
            : "Your university’s sign-in opens here."
        let signedIn = session.signedInSiteID == site.id
        signInMethod.isHidden = signedIn || !site.capabilities.requiresSSO
        credentials?.isHidden = site.capabilities.requiresSSO || signedIn
        username.isHidden = site.capabilities.requiresSSO || signedIn
        password.isHidden = site.capabilities.requiresSSO || signedIn
        message.stringValue = signedIn ? "Signed in to \(site.displayName)." : ""
        if signedIn {
            navigator?.resetButton()
            navigator?.setContinueEnabled(true)
            return
        }
        navigator?.setButtonAction(label: "Sign In") { [weak self] in await self?.signIn() }
        updateEnabled()
        if !site.capabilities.requiresSSO {
            view.window?.makeFirstResponder(username)
            if let editor = username.currentEditor() { SetupAppearance.configureLiteralInputEditor(editor) }
        }
    }

    func controlTextDidChange(_ obj: Notification) { updateEnabled() }

    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        SetupAppearance.configureLiteralInputEditor(fieldEditor)
        return true
    }

    private func updateEnabled() {
        navigator?.setContinueEnabled(session.site?.capabilities.requiresSSO == true ||
            (!username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.stringValue.isEmpty))
    }

    private func signIn() async {
        guard let site = session.site else { return }
        let attempt = UUID()
        signInAttempt = attempt
        defer { if signInAttempt == attempt { signInAttempt = nil } }
        message.stringValue = "Signing in…"
        do {
            if site.capabilities.loginType == .browser {
                try await state.signInWithBrowserSSOAndPersist(site: site, presentationContext: self)
            } else if site.capabilities.requiresSSO {
                try await state.signInAndPersist(site: site) { [weak self] in
                    guard let self, self.signInAttempt == attempt, !Task.isCancelled else { throw CancellationError() }
                    let coordinator = EmbeddedAuthCoordinator()
                    self.embedded = coordinator
                    try coordinator.configure(site: site)
                    try self.showEmbeddedSignIn(coordinator)
                    coordinator.loadLaunchPage()
                    let result = try await coordinator.waitForResult()
                    guard self.signInAttempt == attempt, !Task.isCancelled else { throw CancellationError() }
                    self.removeEmbeddedSignIn()
                    return result.token
                }
            } else {
                try await state.signInAndPersist(site: site,
                    username: username.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), password: password.stringValue)
            }
            guard signInAttempt == attempt, !Task.isCancelled else { return }
            session.signedInSiteID = site.id
            session.password = ""
            password.stringValue = ""
            username.isHidden = true
            password.isHidden = true
            credentials?.isHidden = true
            signInMethod.isHidden = true
            message.stringValue = "Signed in to \(site.displayName)."
            navigator?.resetButton()
            navigator?.setContinueEnabled(true)
        } catch {
            guard signInAttempt == attempt else { return }
            removeEmbeddedSignIn()
            if error is CancellationError || (error as? FindleError)?.isCancelled == true {
                message.stringValue = "Sign-in cancelled."
            } else { message.stringValue = error.localizedDescription }
            updateEnabled()
        }
    }

    override func cancelPendingWork() {
        super.cancelPendingWork()
        signInAttempt = nil
        removeEmbeddedSignIn()
    }

    /// Keep the strong WKWebView local out of the async sign-in frame. The
    /// coordinator can then release it before deleting its persistent store.
    private func showEmbeddedSignIn(_ coordinator: EmbeddedAuthCoordinator) throws {
        guard let web = coordinator.webView else { throw FindleError.cancelled }
        let container = NSView()
        browserContainer = container
        let cancel = ActionButton("Cancel Sign-In") { [weak coordinator] _ in coordinator?.cancel() }
        let content = NativeUI.stack([cancel, web], spacing: 8)
        NativeUI.pin(content, in: container)
        web.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        view.addSubview(container)
        NativeUI.pin(container, in: view)
        stack.isHidden = true
    }

    private func removeEmbeddedSignIn() {
        let coordinator = embedded
        embedded = nil
        browserContainer?.removeFromSuperview()
        browserContainer = nil
        stack.isHidden = false
        coordinator?.cancel()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? NSWindow()
    }
}
