import AppKit

/// Gives each setup step a recognizable subject: Findle, a university, or Finder.
@MainActor
final class SetupContextView: NSView {
    private let imageView = NSImageView()
    private let titleField: NSTextField
    private let detailField = NativeUI.label("", secondary: true, size: 13)

    init(image: NSImage?, title: String, detail: String, imageSize: CGFloat = 32, titleSize: CGFloat = 14) {
        titleField = NativeUI.label(title, size: titleSize, weight: .semibold)
        super.init(frame: .zero)
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.contentTintColor = .controlAccentColor
        imageView.setAccessibilityElement(false)
        detailField.stringValue = detail
        detailField.isHidden = detail.isEmpty
        let text = NativeUI.stack([titleField, detailField], spacing: 3)
        let row = NativeUI.stack([imageView, text], spacing: 12, horizontal: true)
        NativeUI.pin(row, in: self)
        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalToConstant: imageSize),
            imageView.heightAnchor.constraint(equalToConstant: imageSize),
            text.widthAnchor.constraint(equalTo: widthAnchor, constant: -imageSize - 12),
            titleField.widthAnchor.constraint(equalTo: text.widthAnchor),
            detailField.widthAnchor.constraint(equalTo: text.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(title: String, detail: String, image: NSImage? = nil) {
        titleField.stringValue = title
        detailField.stringValue = detail
        detailField.isHidden = detail.isEmpty
        if let image { imageView.image = image }
    }
}

@MainActor
enum SetupAppearance {
    static var appIcon: NSImage? {
        NSImage(named: "OnboardingIcon") ?? NSImage(named: NSImage.applicationIconName)
    }

    static var finderIcon: NSImage {
        NSWorkspace.shared.icon(forFile: "/System/Library/CoreServices/Finder.app")
    }

    static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 36, weight: .regular))
    }

    static func configure(_ field: NSTextField) {
        field.font = .systemFont(ofSize: 13)
        field.controlSize = .large
        field.bezelStyle = .roundedBezel
        // The large control size sets the height and keeps the text vertically centred.
    }

    /// Addresses and credentials are literal input. AppKit otherwise flushes
    /// pending data detection while its field editor resigns first responder,
    /// which can synchronously wait on the scanner during step navigation.
    static func configureLiteralInputEditor(_ fieldEditor: NSText) {
        guard let editor = fieldEditor as? NSTextView else { return }
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
    }
}
