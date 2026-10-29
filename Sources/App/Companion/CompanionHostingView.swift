import AppKit
import SwiftUI

final class CompanionHostingView: NSHostingView<CompanionView> {
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
