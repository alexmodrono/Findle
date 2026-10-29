import AppKit
import SharedDomain

@MainActor
final class AssistantSettingsController: NativeFormController {
    private let state: AppState
    private let message = NativeUI.label("", secondary: true)
    private var token = ClaudeIntegration.generateToken()

    init(state: AppState) { self.state = state; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        NativeUI.section("Claude", in: stack)
        for target in ClaudeIntegration.Target.allCases {
            let connect = ActionButton("Connect \(target.displayName)") { [weak self] _ in
                guard let self else { return }
                switch ClaudeIntegration.install(target, databasePath: self.state.databaseFilePath) {
                case .installed: self.message.stringValue = "Restart \(target.displayName) to load Findle’s tools."
                case .copiedToClipboard: self.message.stringValue = "Configuration copied. Paste it into \(target.displayName)’s settings."
                }
            }
            let remove = ActionButton("Disconnect") { [weak self] _ in
                let removed = ClaudeIntegration.uninstall(target)
                self?.message.stringValue = removed ? "Findle disconnected from \(target.displayName)." : "No Findle configuration was removed."
            }
            remove.setAccessibilityLabel("Disconnect \(target.displayName)")
            stack.addArrangedSubview(NativeUI.stack([connect, remove], spacing: 10, horizontal: true))
        }
        stack.addArrangedSubview(message)
        NativeUI.section("Other assistants", in: stack)
        stack.addArrangedSubview(NativeUI.label("The bundled MCP server supports stdio and authenticated HTTP. Remote assistants need a publicly reachable HTTPS endpoint.", secondary: true))
        stack.addArrangedSubview(ActionButton("Copy HTTP Server Command") { [weak self] _ in
            guard let self else { return }
            let command = ClaudeIntegration.chatGPTCommand(token: self.token, port: Int(BundleIdentifiers.mcpPort), databasePath: self.state.databaseFilePath)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            self.message.stringValue = "Command copied. Keep the bearer token private."
        })
    }
}
