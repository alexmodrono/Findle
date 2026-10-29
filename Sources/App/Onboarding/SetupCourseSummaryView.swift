import AppKit
import SharedDomain

/// A short review of the user's actual course selection before the first sync.
@MainActor
final class SetupCourseSummaryView: NSView {
    private let rows = NativeUI.stack(spacing: 10)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NativeUI.pin(rows, in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ courses: [MoodleCourse]) {
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        isHidden = courses.isEmpty
        for course in courses.prefix(3) {
            let image = NSImageView(image: NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage())
            image.contentTintColor = .systemBlue
            image.setAccessibilityElement(false)
            let name = NSTextField(labelWithString: course.fullName)
            name.font = .systemFont(ofSize: 14)
            name.lineBreakMode = .byTruncatingTail
            name.toolTip = course.fullName
            name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NativeUI.stack([image, name], spacing: 10, horizontal: true)
            rows.addArrangedSubview(row)
            NSLayoutConstraint.activate([
                row.widthAnchor.constraint(equalTo: rows.widthAnchor),
                image.widthAnchor.constraint(equalToConstant: 20),
                image.heightAnchor.constraint(equalToConstant: 20),
                name.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -30)
            ])
        }
        if courses.count > 3 {
            rows.addArrangedSubview(NativeUI.label("And \(courses.count - 3) more", secondary: true))
        }
    }
}
