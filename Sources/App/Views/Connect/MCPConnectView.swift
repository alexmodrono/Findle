// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import AppKit
import SharedDomain

/// A dedicated, reusable window for connecting Findle's bundled MCP server to
/// assistants — one-click for Claude (Desktop/Code), and a friendly, guided
/// setup for ChatGPT over an HTTP tunnel. Openable any time, not just from the
/// What's New sheet.
struct MCPConnectView: View {
    @EnvironmentObject private var appState: AppState

    @State private var installed: Set<ClaudeIntegration.Target> = []
    @State private var token = ClaudeIntegration.generateToken()
    @State private var toast: String?

    // Release and Nightly bind different loopback ports so both can run at once.
    private let port = Int(BundleIdentifiers.mcpPort)

    var body: some View {
        VStack(spacing: 0) {
            hero
            ScrollView {
                VStack(spacing: 16) {
                    claudeCard
                    chatGPTCard
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 700)
        .background(.background)
        .overlay(alignment: .bottom) { toastView }
        .onAppear {
            installed = Set(ClaudeIntegration.Target.allCases.filter(ClaudeIntegration.isInstalled))
        }
    }

    // MARK: - Hero

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [.teal, .blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 110))
                        .foregroundStyle(.white.opacity(0.12))
                        .offset(x: 20, y: -8)
                }
            VStack(alignment: .leading, spacing: 6) {
                Text("AI CONNECTIONS")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Connect Findle to your assistant")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                Text("Let Claude or ChatGPT search, read, and reason over your synced coursework.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(24)
        }
        .frame(height: 170)
        .clipped()
    }

    // MARK: - Claude

    private var claudeCard: some View {
        card(title: "Claude", systemImage: "checkmark.seal.fill", tint: .orange) {
            Text("Adds the bundled MCP server to Claude's config. Restart Claude afterward to load Findle's tools.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                claudeButton(.desktop)
                claudeButton(.code)
            }
        }
    }

    private func claudeButton(_ target: ClaudeIntegration.Target) -> some View {
        let isAdded = installed.contains(target)
        return Button {
            let wasAdded = installed.contains(target)
            switch ClaudeIntegration.install(target, databasePath: appState.databaseFilePath) {
            case .installed:
                installed.insert(target)
                showToast("\(wasAdded ? "Updated" : "Added to") \(target.displayName) — restart it to load \(BundleIdentifiers.appDisplayName).")
            case .copiedToClipboard:
                showToast("Couldn't write the config — it's copied to your clipboard.")
            }
        } label: {
            Label(isAdded ? "Added to \(target.displayName)" : "Add to \(target.displayName)",
                  systemImage: isAdded ? "checkmark" : "plus")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .controlSize(.large)
        .buttonStyle(.borderedProminent)
        .tint(isAdded ? .green : .accentColor)
        .disabled(!target.isLikelyInstalled)
        .help(target.isLikelyInstalled ? "" : "\(target.displayName) doesn't appear to be installed")
        // Removal only touches this build's own entry, so a Nightly install can
        // be undone without disturbing the release app's registration.
        .contextMenu {
            if isAdded {
                Button("Remove from \(target.displayName)", role: .destructive) {
                    if ClaudeIntegration.uninstall(target) {
                        installed.remove(target)
                        showToast("Removed from \(target.displayName) — restart it to apply.")
                    }
                }
            }
        }
    }

    // MARK: - ChatGPT

    private var command: String {
        ClaudeIntegration.chatGPTCommand(token: token, port: port, databasePath: appState.databaseFilePath)
    }

    private var chatGPTCard: some View {
        card(title: "ChatGPT (via a tunnel)", systemImage: "network", tint: .green) {
            Text("ChatGPT connects over the internet, so you run the server yourself and expose it with a tunnel (e.g. ngrok). The token below is its only lock — keep it secret.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            labeledCopyRow(label: "Token", value: token, mono: true) {
                Button {
                    token = ClaudeIntegration.generateToken()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Generate a new token")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Run this in Terminal").font(.subheadline.weight(.medium))
                copyBox(command)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("2. Tunnel it").font(.subheadline.weight(.medium))
                copyBox("ngrok http \(port)")
                Text("Install ngrok first (`brew install ngrok`) and add your authtoken.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("3. Add it to ChatGPT").font(.subheadline.weight(.medium))
                Text("Add a remote MCP server with the **https://…ngrok** URL ngrok prints, and an `Authorization: Bearer <token>` header.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func card<Content: View>(title: String, systemImage: String, tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func labeledCopyRow<Trailing: View>(label: String, value: String, mono: Bool, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.subheadline.weight(.medium))
            Text(value)
                .font(mono ? .system(.callout, design: .monospaced) : .callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing()
            copyButton(value)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.vertical, 2)
            }
            copyButton(text)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyButton(_ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            showToast("Copied to clipboard")
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }

    // MARK: - Toast

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
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.spring) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(.spring) { toast = nil }
        }
    }
}
