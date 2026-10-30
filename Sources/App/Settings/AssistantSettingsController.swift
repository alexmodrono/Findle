import AppKit
import SharedDomain

@MainActor
final class AssistantSettingsController: SettingsFormController {
    private let state: AppState
    private let message = NSTextField(wrappingLabelWithString: "")
    private var token = ClaudeIntegration.generateToken()

    init(state: AppState) { self.state = state; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        for target in ClaudeIntegration.Target.allCases {
            let connect = ActionButton("Connect") { [weak self] _ in
                guard let self else { return }
                switch ClaudeIntegration.install(target, databasePath: self.state.databaseFilePath) {
                case .installed: self.show("Restart \(target.displayName) to load Findle’s tools.")
                case .copiedToClipboard: self.show("Configuration copied. Paste it into \(target.displayName)’s settings.")
                }
            }
            connect.setAccessibilityLabel("Connect \(target.displayName)")
            let remove = ActionButton("Disconnect") { [weak self] _ in
                let removed = ClaudeIntegration.uninstall(target)
                self?.show(removed ? "Findle disconnected from \(target.displayName)." : "No Findle configuration was removed.")
            }
            remove.setAccessibilityLabel("Disconnect \(target.displayName)")
            addRow(target.displayName, buttons([connect, remove]))
        }
        addSeparator()
        addRow("Other assistants", ActionButton("Copy HTTP Server Command") { [weak self] _ in
            guard let self else { return }
            let command = ClaudeIntegration.chatGPTCommand(token: self.token, port: Int(BundleIdentifiers.mcpPort), databasePath: self.state.databaseFilePath)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            self.show("Command copied. Keep the bearer token private.")
        })
        addNote(NSTextField(wrappingLabelWithString: "Remote assistants need a publicly reachable HTTPS endpoint."))
        let result = addNote(message)
        message.textColor = .labelColor
        result.topPadding = 12
        result.isHidden = true
    }

    private func show(_ text: String) {
        message.stringValue = text
        grid.cell(for: message)?.row?.isHidden = false
    }
}
