import SwiftUI
import SharedDomain

struct CourseDetailView: View {
    @EnvironmentObject private var appState: AppState

    let course: MoodleCourse
    let isSyncing: Bool

    @State private var customFolderName = ""
    @State private var tags: [FinderTag] = []
    @State private var isAddingTag = false
    @State private var newTagName = ""
    @State private var newTagColor: FinderTag.Color = .blue
    @State private var localSyncEnabled = true

    var body: some View {
        Form {
            Section {
                CourseDetailHeader(course: course)
            }

            Section("Finder") {
                LabeledContent("Folder name") {
                    TextField(course.sanitizedFolderName, text: $customFolderName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .onSubmit { saveFolderName() }
                }

                LabeledContent("Tags") {
                    HStack(spacing: 4) {
                        FlowLayout(spacing: 4) {
                            ForEach(tags, id: \.self) { tag in
                                TagBadge(tag: tag) {
                                    removeTag(tag)
                                }
                            }
                        }

                        Button("Add Tag", systemImage: "plus") {
                            isAddingTag = true
                        }
                        .buttonStyle(.accessoryBar)
                        .controlSize(.small)
                        .popover(isPresented: $isAddingTag) {
                            AddTagPopover(
                                name: $newTagName,
                                color: $newTagColor,
                                onAdd: { addTag() },
                                onCancel: { isAddingTag = false }
                            )
                        }
                    }
                }
            }

            Section("Sync") {
                Toggle("Sync this course", isOn: $localSyncEnabled)
                    .onChange(of: localSyncEnabled) { _, newValue in
                        appState.setCourseSyncEnabled(newValue, for: course)
                    }

                if !localSyncEnabled {
                    Text("This course will be skipped during sync and hidden from Finder.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let summary = cleanedSummary {
                Section("About") {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(course.effectiveFolderName)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Sync", systemImage: "arrow.clockwise", action: syncCourse)
                    .help("Sync this course")
                    .disabled(isSyncing || !localSyncEnabled)
                    .overlay {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
            }
        }
        .task(id: course.id) {
            loadCustomization()
        }
    }

    // MARK: - Computed

    private var cleanedSummary: String? {
        guard let summary = course.summary else { return nil }
        let cleaned = summary
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Actions

    private func loadCustomization() {
        customFolderName = course.customFolderName ?? ""
        tags = appState.fetchCourseTags(for: course)
        localSyncEnabled = course.isSyncEnabled
    }

    private func saveFolderName() {
        let trimmed = customFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        appState.updateCustomFolderName(for: course, name: trimmed.isEmpty ? nil : trimmed)
    }

    private func addTag() {
        let trimmed = newTagName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !tags.contains(where: { $0.name == trimmed }) else { return }

        let tag = FinderTag(name: trimmed, color: newTagColor)
        tags.append(tag)
        appState.updateCourseTags(for: course, tags: tags)

        newTagName = ""
        newTagColor = .blue
        isAddingTag = false
    }

    private func removeTag(_ tag: FinderTag) {
        tags.removeAll { $0 == tag }
        appState.updateCourseTags(for: course, tags: tags)
    }

    private func syncCourse() {
        Task { await appState.syncCourse(course) }
    }
}
