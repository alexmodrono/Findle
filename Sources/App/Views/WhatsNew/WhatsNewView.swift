// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI

/// A custom, animated "What's New" showcase. Replaces WhatsNewKit with a richer
/// layout: a gradient hero, staggered feature cards, and a featured card that
/// registers the bundled MCP server with Claude in one click.
struct WhatsNewView: View {
    let release: WhatsNewRelease
    let databasePath: String?
    let onDismiss: () -> Void

    @State private var appeared = false
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            hero

            ScrollView {
                VStack(spacing: 14) {
                    ForEach(Array(release.sections.enumerated()), id: \.element.id) { index, section in
                        animatedCard(index: index, section: section)
                    }
                }
                .padding(20)
            }

            footer
        }
        .frame(width: 540, height: 660)
        .background(.background)
        .overlay(alignment: .bottom) { toastView }
        .onAppear { appeared = true }
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [.purple, .blue, .cyan],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .overlay(alignment: .topTrailing) {
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 120))
                    .foregroundStyle(.white.opacity(0.12))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 24, y: -10)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(release.subheadline.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.18), in: Capsule())

                Text(release.headline)
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .frame(height: 180)
        .clipped()
    }

    // MARK: - Cards

    private func animatedCard(index: Int, section: WhatsNewRelease.Section) -> some View {
        card(section)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 20)
            .animation(.spring(response: 0.55, dampingFraction: 0.82).delay(Double(index) * 0.08), value: appeared)
    }

    @ViewBuilder
    private func card(_ section: WhatsNewRelease.Section) -> some View {
        switch section.style {
        case .standard:
            standardCard(section)
        case .connectToClaude:
            claudeCard(section)
        }
    }

    private func standardCard(_ section: WhatsNewRelease.Section) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: section.icon)
                .font(.title2)
                .foregroundStyle(section.tint)
                .frame(width: 44, height: 44)
                .background(section.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(section.title).font(.headline)
                Text(section.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func claudeCard(_ section: WhatsNewRelease.Section) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: section.icon)
                    .font(.title2)
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(section.title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
            }

            Text(section.body)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                connectButton(.desktop)
                connectButton(.code)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [section.tint, .purple], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .shadow(color: section.tint.opacity(0.35), radius: 10, y: 4)
    }

    private func connectButton(_ target: ClaudeIntegration.Target) -> some View {
        Button {
            connect(target)
        } label: {
            Label("Add to \(target.displayName)", systemImage: "plus")
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.22), in: Capsule())
        .foregroundStyle(.white)
        .disabled(!target.isLikelyInstalled)
        .opacity(target.isLikelyInstalled ? 1 : 0.5)
        .help(target.isLikelyInstalled ? "Register Findle's MCP server with \(target.displayName)" : "\(target.displayName) doesn't appear to be installed")
    }

    private func connect(_ target: ClaudeIntegration.Target) {
        switch ClaudeIntegration.install(target, databasePath: databasePath) {
        case .installed:
            showToast("Added to \(target.displayName) — restart it to load Findle's tools.")
        case .copiedToClipboard:
            showToast("Couldn't write the config automatically — it's copied to your clipboard.")
        }
    }

    // MARK: - Footer & toast

    private var footer: some View {
        HStack {
            Spacer()
            Button("Continue", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(20)
        .background(.bar)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary))
                .shadow(radius: 8, y: 2)
                .padding(.bottom, 80)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.spring) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.spring) { toast = nil }
        }
    }
}
