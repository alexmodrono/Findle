// Copyright 2026 Alejandro Modroño Vara <amodrono@alu.icai.comillas.edu>
//
// Licensed under the Apache License, Version 2.0.
// You may obtain a copy of the License in the LICENSE file at the root of this repository.

import SwiftUI
import SharedDomain

// Grouped forms, like Findle's Settings window. They follow light, dark and
// Increased Contrast on their own.

@MainActor
@Observable
final class CourseInfoModel {
    let client: CourseDataClient
    let courseID: Int?
    var info: CourseDataService.CourseInfo?
    var error: String?
    var updatingKept = false

    init(client: CourseDataClient, courseID: Int?) {
        self.client = client
        self.courseID = courseID
    }

    func load() async {
        guard let courseID else { error = CourseDataClient.Failure.unavailable.errorDescription; return }
        do { info = try await client.courseInfo(courseID: courseID) } catch { self.error = error.localizedDescription }
    }

    func setKept(_ kept: Bool) async {
        guard let courseID else { return }
        updatingKept = true
        defer { updatingKept = false }
        do {
            try await client.setKeptOffline(courseID: courseID, kept: kept)
            info = try await client.courseInfo(courseID: courseID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct CourseInfoView: View {
    let model: CourseInfoModel
    let done: () -> Void

    var body: some View {
        SheetFrame(title: model.info?.fullName ?? "Course Info", error: model.error, loading: model.info == nil, done: done) {
            if let info = model.info {
                Form {
                    Section {
                        LabeledContent("Course", value: info.shortName)
                        LabeledContent(info.teachers.count == 1 ? "Teacher" : "Teachers",
                                       value: info.teachers.isEmpty ? "Not listed" : info.teachers.joined(separator: ", "))
                        LabeledContent("Last synced", value: info.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "Not yet")
                        LabeledContent("On this Mac", value: ByteCountFormatter.string(fromByteCount: info.storageBytes, countStyle: .file))
                    }
                    Section {
                        Toggle("Keep course offline", isOn: Binding(
                            get: { info.keptOffline },
                            set: { kept in Task { await model.setKept(kept) } }))
                            .disabled(model.updatingKept)
                    } footer: {
                        Text("Keeps every file in the course downloaded, including ones added later.")
                    }
                    if !info.sections.isEmpty {
                        Section("Sections") {
                            ForEach(Array(info.sections.enumerated()), id: \.offset) { _, name in Text(name) }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}

@MainActor
@Observable
final class AssignmentDetailsModel {
    let client: CourseDataClient
    let itemID: String
    var details: CourseDataService.AssignmentDetails?
    var error: String?

    init(client: CourseDataClient, itemID: String) {
        self.client = client
        self.itemID = itemID
    }

    func load() async {
        do { details = try await client.assignmentDetails(itemID: itemID) } catch { self.error = error.localizedDescription }
    }
}

struct AssignmentDetailsView: View {
    let model: AssignmentDetailsModel
    let done: () -> Void

    var body: some View {
        SheetFrame(title: model.details?.name ?? "Assignment Details", error: model.error, loading: model.details == nil,
                   done: done) {
            if let details = model.details {
                Form {
                    Section {
                        LabeledContent("Course", value: details.courseName)
                        LabeledContent("Due", value: details.due?.formatted(date: .abbreviated, time: .shortened) ?? "No due date")
                        if let cutoff = details.cutoff {
                            LabeledContent("Last accepted", value: cutoff.formatted(date: .abbreviated, time: .shortened))
                        }
                        LabeledContent("Status", value: details.status)
                    }
                    if let brief = details.brief, !brief.isEmpty {
                        Section("Brief") {
                            Text(brief).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
    }
}

/// Title, content (or a loading or error state) and a Done button.
struct SheetFrame<Content: View>: View {
    let title: String
    let error: String?
    var loading = false
    let done: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title).font(.headline).lineLimit(2).multilineTextAlignment(.center).padding([.top, .horizontal], 16)
            if let error {
                ContentUnavailableView("Not available", systemImage: "exclamationmark.triangle", description: Text(error))
                    .frame(minHeight: 160)
            } else {
                content
                    .frame(minHeight: 160)
                    .overlay { if loading { ProgressView() } }
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 460)
        .frame(maxHeight: 560)
    }
}
