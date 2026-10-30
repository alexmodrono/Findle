import AppKit

@MainActor
final class WelcomeSetupController: SetupStepController {
    override var scrollsBody: Bool { false }
    override var centersContentVertically: Bool { true }
    override var bodyWidth: CGFloat? { 400 }

    override func buildContent() {
        stack.alignment = .centerX
        stack.spacing = 22
        let icon = NSImageView(image: SetupAppearance.appIcon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        stack.addArrangedSubview(icon)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 80),
            icon.heightAnchor.constraint(equalToConstant: 80)
        ])

        let title = NativeUI.label("Welcome to Findle", size: 26, weight: .semibold)
        let detail = NativeUI.label("Your Moodle courses and files,\nright where you work in Finder.", secondary: true, size: 13)
        title.alignment = .center
        detail.alignment = .center
        let introduction = NativeUI.stack([title, detail], spacing: 6)
        addFullWidth(introduction)
        title.widthAnchor.constraint(equalTo: introduction.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: introduction.widthAnchor).isActive = true

        let features = NativeUI.stack([
            SetupFeatureRow(symbol: "folder", title: "Browse courses in Finder",
                            detail: "Open course materials alongside your other files."),
            SetupFeatureRow(symbol: "arrow.down.document", title: "Download when you need it",
                            detail: "Files download when opened, saving space on your Mac."),
            SetupFeatureRow(symbol: "checklist", title: "Choose what stays in sync",
                            detail: "Select your courses now and change them later in Settings.")
        ], spacing: 14)
        addFullWidth(features)
        features.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: features.widthAnchor).isActive = true }
    }
}
