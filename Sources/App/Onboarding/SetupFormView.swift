import AppKit

/// The section hierarchy used by Crono's grouped onboarding forms.
@MainActor
final class SetupStepHeader: NSView {
    private let titleField = NativeUI.label("", size: 22, weight: .semibold)
    private let detailField = NativeUI.label("", secondary: true, size: 13)

    init(title: String, detail: String) {
        super.init(frame: .zero)
        let text = NativeUI.stack([titleField, detailField], spacing: 4)
        NativeUI.pin(text, in: self)
        titleField.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        detailField.widthAnchor.constraint(equalTo: text.widthAnchor).isActive = true
        update(title: title, detail: detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(title: String, detail: String) {
        titleField.stringValue = title
        detailField.stringValue = detail
        detailField.isHidden = detail.isEmpty
    }
}

/// An opaque grouped-form surface; the separate navigation pill owns the glass.
@MainActor
final class SetupFormGroup: NSView {
    let content = NativeUI.stack(spacing: 12)

    init(_ children: [NSView], inset: CGFloat = 14) {
        super.init(frame: .zero)
        NativeUI.pin(content, in: self, inset: inset)
        for child in children {
            content.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Recent macOS versions resolve control and window backgrounds to the
        // same color. Keep Crono's grouped form hierarchy in either appearance.
        let background = NSColor.windowBackgroundColor.blended(withFraction: 0.045, of: .labelColor)
            ?? .controlBackgroundColor
        background.setFill()
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        shape.fill()
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
            shape.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class SetupFeatureRow: NSView {
    init(symbol: String, title: String, detail: String) {
        super.init(frame: .zero)
        let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        image.symbolConfiguration = .init(pointSize: 22, weight: .regular)
        image.contentTintColor = .controlAccentColor
        image.setAccessibilityElement(false)
        let heading = NativeUI.label(title, size: 13, weight: .semibold)
        let description = NativeUI.label(detail, secondary: true, size: 13)
        let text = NativeUI.stack([heading, description], spacing: 2)
        let row = NativeUI.stack([image, text], spacing: 14, horizontal: true)
        row.alignment = .top
        NativeUI.pin(row, in: self)
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 30),
            image.heightAnchor.constraint(equalToConstant: 28),
            text.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -44),
            heading.widthAnchor.constraint(equalTo: text.widthAnchor),
            description.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
