import AppKit

@MainActor
final class ServerSetupController: SetupStepController, NSTextFieldDelegate {
    private let address = NSTextField()

    override func buildContent() {
        let identity = SetupContextView(image: SetupAppearance.appIcon,
                                        title: "Your courses in Finder", detail: "Moodle & Open LMS",
                                        imageSize: 96, titleSize: 23)
        addFullWidth(identity)
        stack.setCustomSpacing(30, after: identity)
        let label = NativeUI.label("Moodle address", size: 13, weight: .medium)
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(8, after: label)
        address.placeholderString = "https://moodle.example.edu"
        address.stringValue = session.serverURL
        address.setAccessibilityLabel("Moodle site address")
        address.delegate = self
        SetupAppearance.configure(address)
        addFullWidth(address)
    }

    override func prepareForPresentation() {
        configureButton()
        view.window?.makeFirstResponder(address)
        if let editor = address.currentEditor() { SetupAppearance.configureLiteralInputEditor(editor) }
    }

    func controlTextDidChange(_ obj: Notification) {
        session.serverURL = address.stringValue
        session.site = nil
        message.stringValue = ""
        configureButton()
    }

    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        SetupAppearance.configureLiteralInputEditor(fieldEditor)
        return true
    }

    private func configureButton() {
        if let site = session.site {
            message.stringValue = site.displayName
            navigator?.resetButton()
        } else {
            navigator?.setButtonAction(label: "Connect") { [weak self] in
                guard let self else { return }
                self.message.stringValue = "Checking Moodle…"
                do {
                    let site = try await self.state.validateSite(urlString: self.address.stringValue)
                    guard !Task.isCancelled else { return }
                    self.session.site = site
                    self.message.stringValue = site.displayName
                    self.navigator?.resetButton()
                } catch is CancellationError { return }
                catch { self.message.stringValue = error.localizedDescription }
            }
        }
        navigator?.setContinueEnabled(!address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}
