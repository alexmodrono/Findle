import SwiftUI

struct CompanionView: View {
    let presentation: CompanionPresentation
    let actions: CompanionActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98,
            anchor: presentation.attachedOnRight ? .leading : .trailing))
    }

    var body: some View {
        ZStack(alignment: presentation.attachedOnRight ? .topLeading : .topTrailing) {
            if presentation.mode == .compact {
                CompanionCompactView(presentation: presentation, actions: actions)
                    .frame(width: FinderPanelPlacement.Mode.compact.preferredSize.width)
                    .transition(transition)
            } else {
                CompanionExpandedView(presentation: presentation, actions: actions)
                    // Preserve line wrapping as AppKit animates the outer window.
                    .frame(width: presentation.expandedWidth)
                    .transition(transition)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity,
               alignment: presentation.attachedOnRight ? .topLeading : .topTrailing)
        .clipped()
        // This utility remains interactive while Finder owns app activation.
        .environment(\.appearsActive, true)
        .modifier(CompanionMaterial())
    }
}
