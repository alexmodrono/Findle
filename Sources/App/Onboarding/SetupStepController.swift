import AppKit
import Airlock

@MainActor
class SetupStepController: AirlockStepViewController {
    let state: AppState
    let session: SetupSession
    let stack = NativeUI.stack(spacing: 16)
    let message = SetupMessageField(wrappingLabelWithString: "")
    var work: Task<Void, Never>?
    var scrollsBody: Bool { true }
    var centersContentVertically: Bool { false }
    var bodyWidth: CGFloat? { nil }

    init(state: AppState, session: SetupSession) {
        self.state = state; self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
        if scrollsBody {
            let scroll = NSScrollView()
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true
            NativeUI.pin(scroll, in: view)
            let document = FlippedView()
            scroll.documentView = document
            document.translatesAutoresizingMaskIntoConstraints = false
            document.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
                stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
                stack.topAnchor.constraint(equalTo: document.topAnchor),
                stack.bottomAnchor.constraint(equalTo: document.bottomAnchor)
            ])
        } else {
            view.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            if let bodyWidth {
                let preferredWidth = stack.widthAnchor.constraint(equalToConstant: bodyWidth)
                preferredWidth.priority = .defaultHigh
                NSLayoutConstraint.activate([
                    preferredWidth,
                    stack.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor),
                    stack.centerXAnchor.constraint(equalTo: view.centerXAnchor)
                ])
            } else {
                NSLayoutConstraint.activate([
                    stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    stack.trailingAnchor.constraint(equalTo: view.trailingAnchor)
                ])
            }
            if centersContentVertically {
                NSLayoutConstraint.activate([
                    stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                    stack.topAnchor.constraint(greaterThanOrEqualTo: view.topAnchor),
                    stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
                ])
            } else {
                NSLayoutConstraint.activate([
                    stack.topAnchor.constraint(equalTo: view.topAnchor),
                    stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
                ])
            }
        }
        message.font = .systemFont(ofSize: 13)
        message.textColor = .secondaryLabelColor
        message.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        message.isHidden = message.stringValue.isEmpty
        buildContent()
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func buildContent() {}

    func addFullWidth(_ child: NSView) {
        stack.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    override func cancelPendingWork() { work?.cancel(); work = nil }
}
