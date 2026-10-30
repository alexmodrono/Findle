import SwiftUI

/// A solid control surface stays distinct from the translucent panel behind it.
struct CompanionControlSurface: ViewModifier {
    var isPressed = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var isDark: Bool { colorScheme == .dark }

    private var fill: Color {
        let pressed = isPressed && isEnabled, hovered = isHovered && isEnabled
        let level: Double = isDark
            ? pressed ? 0.20 : hovered ? 0.34 : 0.27
            : pressed ? 0.76 : hovered ? 0.93 : 0.86
        return Color(white: level)
    }

    private var stroke: Color {
        let opacity = contrast == .increased ? 0.5 : isDark ? 0.12 : 0.14
        return (isDark ? Color.white : Color.black).opacity(opacity)
    }

    func body(content: Content) -> some View {
        content
            .foregroundStyle(Color(white: isDark ? 0.92 : 0.16))
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(fill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(stroke, lineWidth: contrast == .increased ? 1 : 0.5)
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
