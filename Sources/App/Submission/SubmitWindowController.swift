// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import AppKit
import SwiftUI

/// "Submit to Moodle": where files shared to Findle go (FX-07). The user picks
/// the assignment, then saves them as a draft or, after confirming, submits.
@MainActor
final class SubmitWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(state: AppState, files: [URL]) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 380),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Submit to Moodle"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SubmitView(
            files: files, assignments: state.submittableAssignments(),
            submit: { assignment, forGrading, statement in
                try await state.submitShared(files: files, to: assignment, forGrading: forGrading, acceptStatement: statement)
            },
            close: { [weak self] in self?.close() }))
        window.delegate = self
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func present() {
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

struct SubmitView: View {
    let files: [URL]
    let assignments: [SubmittableAssignment]
    let submit: (SubmittableAssignment, Bool, Bool) async throws -> Void
    let close: () -> Void

    @State private var selection: SubmittableAssignment?
    @State private var acceptsStatement = false
    @State private var confirming = false
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Files") {
                    ForEach(files, id: \.self) { Label($0.lastPathComponent, systemImage: "doc") }
                }
                Section {
                    if assignments.isEmpty {
                        Text("No open assignment takes files right now. Sync your courses in Findle and try again.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Assignment", selection: $selection) {
                            Text("Choose…").tag(SubmittableAssignment?.none)
                            ForEach(assignments) { assignment in
                                Text("\(assignment.name) — \(assignment.courseName)").tag(Optional(assignment))
                            }
                        }
                        if selection?.requiresStatement == true {
                            Toggle("I accept this site's submission statement", isOn: $acceptsStatement)
                        }
                    }
                } footer: {
                    Text("The files go into the assignment's Submit folder in Finder and become your draft on Moodle.")
                }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
                Button("Save as Draft") { run(forGrading: false) }
                    .disabled(selection == nil || working)
                Button("Submit for Grading…") { confirming = true }
                    .disabled(selection?.canSubmit != true || working
                              || (selection?.requiresStatement == true && !acceptsStatement))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460)
        .confirmationDialog("Submit \(selection?.name ?? "") for grading?", isPresented: $confirming) {
            Button("Submit for Grading") { run(forGrading: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your teacher sees the submission, and you may not be able to change it afterwards.")
        }
    }

    private func run(forGrading: Bool) {
        guard let selection else { return }
        working = true
        Task {
            do {
                try await submit(selection, forGrading, acceptsStatement)
                close()
            } catch {
                message = error.localizedDescription
                working = false
            }
        }
    }
}
