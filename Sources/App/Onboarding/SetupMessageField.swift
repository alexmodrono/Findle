import AppKit

/// Empty status text should not leave a blank row in the form.
@MainActor
final class SetupMessageField: NSTextField {
    override var stringValue: String {
        didSet {
            isHidden = stringValue.isEmpty
            toolTip = stringValue.isEmpty ? nil : stringValue
        }
    }
}
