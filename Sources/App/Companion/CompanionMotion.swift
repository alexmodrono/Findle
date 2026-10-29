import AppKit
import SwiftUI

@MainActor
enum CompanionMotion {
    static let resizeDuration: TimeInterval = 0.22

    static var isPointerInteraction: Bool {
        switch NSApp.currentEvent?.type {
        case .keyDown, .keyUp, .flagsChanged: false
        default: true
        }
    }

    static func contentTransition(animated: Bool) -> Animation? {
        guard animated else { return nil }
        return .easeOut(duration: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.18)
    }
}
