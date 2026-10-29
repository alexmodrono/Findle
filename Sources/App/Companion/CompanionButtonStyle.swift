import SwiftUI

struct CompanionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(CompanionControlSurface(isPressed: configuration.isPressed))
    }
}
