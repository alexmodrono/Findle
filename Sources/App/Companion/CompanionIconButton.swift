import SwiftUI

struct CompanionIconButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.body)
                .imageScale(.large)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .buttonStyle(CompanionButtonStyle())
        .help(title)
    }
}
