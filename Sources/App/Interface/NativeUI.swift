import AppKit

@MainActor
final class ActionButton: NSButton {
    private let handler: @MainActor (ActionButton) -> Void

    init(_ title: String, checkbox: Bool = false, handler: @escaping @MainActor (ActionButton) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        if checkbox { setButtonType(.switch) } else { bezelStyle = .rounded }
        target = self
        action = #selector(invoke)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func invoke() { handler(self) }
}

@MainActor
enum NativeUI {
    static func label(_ text: String, secondary: Bool = false, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    static func stack(_ views: [NSView] = [], spacing: CGFloat = 16, horizontal: Bool = false) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = horizontal ? .horizontal : .vertical
        stack.alignment = horizontal ? .centerY : .leading
        stack.spacing = spacing
        return stack
    }

    static func pin(_ child: NSView, in parent: NSView, inset: CGFloat = 0) {
        parent.addSubview(child)
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    static func section(_ title: String, in stack: NSStackView) {
        let label = label(title, size: 15, weight: .semibold)
        if let previous = stack.arrangedSubviews.last { stack.setCustomSpacing(28, after: previous) }
        stack.addArrangedSubview(label)
    }

    static func confirm(in window: NSWindow?, title: String, message: String, actionTitle: String,
                        action: @escaping @MainActor () -> Void) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: actionTitle)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action() }
        }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class NativeSurface: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

@MainActor
class NativeFormController: NSViewController {
    let stack = NativeUI.stack()

    override func loadView() {
        view = NativeSurface()
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        NativeUI.pin(scroll, in: view)
        let document = FlippedView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28)
        ])
        buildForm()
    }

    func buildForm() {}
}
