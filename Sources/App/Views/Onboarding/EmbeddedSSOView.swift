import SwiftUI
import WebKit
import SharedDomain
import FoodleNetworking

/// A SwiftUI wrapper around the `EmbeddedAuthCoordinator`'s WKWebView.
/// Presented as a sheet during onboarding when the site uses `SiteLoginType.embedded`.
struct EmbeddedSSOView: View {
    let site: MoodleSite
    let coordinator: EmbeddedAuthCoordinator
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Spacer()

                Button("Cancel") {
                    coordinator.cancel()
                    onCancel()
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            // Web view
            EmbeddedWebViewRepresentable(coordinator: coordinator)
        }
        .frame(minWidth: 600, minHeight: 500)
    }
}

/// NSViewRepresentable wrapping the coordinator's WKWebView.
private struct EmbeddedWebViewRepresentable: NSViewRepresentable {
    let coordinator: EmbeddedAuthCoordinator

    func makeNSView(context: Context) -> WKWebView {
        coordinator.webView!
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
