import SwiftUI

struct CompanionMaterial: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: .rect(cornerRadius: 20))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            content.background(.regularMaterial, in: .rect(cornerRadius: 20))
        }
    }
}
