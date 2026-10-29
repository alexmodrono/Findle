import SwiftUI

/// A solid control surface stays distinct from the translucent panel behind it.
struct CompanionControlSurface: ViewModifier {
    var isPressed = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var fill: Color {
        let level: Double = isPressed && isEnabled ? 0.76
            : isHovered && isEnabled ? 0.93
            : colorScheme == .dark ? 0.82 : 0.86
        return Color(white: level)
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color(white: 0.16))
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(.black.opacity(contrast == .increased ? 0.5 : 0.14),
                                          lineWidth: contrast == .increased ? 1 : 0.5)
                    }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(isPressed && isEnabled && !reduceMotion && CompanionMotion.isPointerInteraction ? 0.97 : 1)
            .animation(CompanionMotion.isPointerInteraction ? .easeOut(duration: isPressed ? 0.1 : 0.16) : nil,
                       value: isPressed)
            .animation(.easeOut(duration: isHovered ? 0.12 : 0.16), value: isHovered)
            .onHover { isHovered = $0 && isEnabled }
    }
}
