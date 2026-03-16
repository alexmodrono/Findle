// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

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
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(site.displayName)
                        .font(.headline)

                    Text("Continue signing in without leaving Findle.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Cancel", systemImage: "xmark.circle", action: onCancel)
                    .controlSize(.regular)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.bar)

            Divider()

            EmbeddedWebViewRepresentable(coordinator: coordinator)
                .onAppear {
                    coordinator.loadLaunchPage()
                }
        }
        .frame(minWidth: 760, minHeight: 580)
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
