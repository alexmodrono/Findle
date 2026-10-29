import AppKit
import QuartzCore

/// Coalesce state refreshes so they cannot snap an in-flight window resize.
@MainActor
final class CompanionFrameAnimator {
    private var target: NSRect?
    private var generation = UUID()
    private var isAnimating = false

    func setFrame(_ frame: NSRect, of window: NSWindow, animated: Bool) {
        guard target != frame || (!isAnimating && window.frame != frame) else { return }
        target = frame
        generation = UUID()
        let current = generation
        isAnimating = animated
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? CompanionMotion.resizeDuration : 0
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
            window.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current else { return }
                self.isAnimating = false
            }
        }
    }
}
