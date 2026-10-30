import AppKit
import Combine
import UniformTypeIdentifiers
import SharedDomain

@MainActor
final class DiagnosticsController: SettingsFormController {
    private let state: AppState
    private let lastSync = NSTextField(labelWithString: "")
    private let database = NSTextField(labelWithString: "")
    private let failure = NSTextField(wrappingLabelWithString: "")
    private var subscription: AnyCancellable?
    private var isExporting = false

    init(state: AppState) { self.state = state; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        database.isSelectable = true
        database.lineBreakMode = .byTruncatingMiddle
        database.widthAnchor.constraint(lessThanOrEqualToConstant: Self.controlWidth).isActive = true
        failure.isSelectable = true
        failure.textColor = .systemRed
        failure.preferredMaxLayoutWidth = Self.controlWidth
        failure.widthAnchor.constraint(lessThanOrEqualToConstant: Self.controlWidth).isActive = true
        addRow("Last sync", lastSync)
        addRow("Last error", failure)
        addRow("Database", database)
        addSeparator()
        let verbose = ActionButton("Verbose logging", checkbox: true) { button in UserDefaults.standard.set(button.state == .on, forKey: "verboseLogging") }
        verbose.state = UserDefaults.standard.bool(forKey: "verboseLogging") ? .on : .off
        addRow("Logging", verbose)
        addRow(nil, ActionButton("Export Diagnostics…") { [weak self] _ in self?.export() })
        addSeparator()
        let reset = ActionButton("Reset File Provider…") { [weak self] _ in
            guard let self else { return }
            NativeUI.confirm(in: self.view.window, title: "Reset File Provider?",
                             message: "Findle will register its Finder location again. Downloaded Moodle files may need to be downloaded again. Your personal files are preserved.",
                             actionTitle: "Reset") { Task { await self.state.resetProvider() } }
        }
        reset.hasDestructiveAction = true
        addRow("Maintenance", buttons([ActionButton("Rebuild Search Index") { [weak self] _ in
            guard let self else { return }; Task { await self.state.rebuildIndex() }
        }, reset]))
        subscription = state.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        lastSync.stringValue = state.lastSyncDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
        database.stringValue = state.databaseFilePath ?? "Unavailable"
        database.toolTip = state.databaseFilePath
        showFailure(state.errorMessage)
    }

    private func showFailure(_ message: String?) {
        failure.stringValue = message ?? ""
        grid.cell(for: failure)?.row?.isHidden = message?.isEmpty ?? true
    }

    private func export() {
        guard !isExporting, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "findle-diagnostics.json"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.isExporting = true
            // Capture the current session once, before the asynchronous probes.
            // Never serialize errorMessage or String(describing: syncStatus): both
            // can contain a server response, callback payload, or a personal path.
            let report = self.state.lastSyncReport
            let status: String
            switch self.state.syncStatus {
            case .idle: status = "idle"
            case .syncing: status = "syncing"
            case .completed: status = "completed"
            case .error: status = (report?.succeededCount ?? 0) > 0 ? "partial" : "error"
            }
            let input = DiagnosticsReportBuilder.Input(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                revision: Bundle.main.object(forInfoDictionaryKey: "FindleSourceRevision") as? String,
                channel: BundleIdentifiers.isNightly ? "nightly" : "release",
                databasePath: self.state.databaseFilePath, additionalDatabasePaths: Array(self.state.diagnosticDatabasePaths),
                databaseFailure: self.state.databaseInitializationFailure, siteID: self.state.currentSite?.id,
                syncState: status, lastSuccessfulSync: self.state.lastSyncDate, syncAttemptID: report?.id,
                courses: report?.courses.map { .init(courseID: $0.courseID, outcome: $0.outcome.rawValue, failure: $0.failure) } ?? []
            )
            Task {
                defer { self.isExporting = false }
                let diagnostics = await DiagnosticsReportBuilder.capture(input)
                do {
                    let data = try diagnostics.encoded()
                    try await Task.detached(priority: .utility) { try data.write(to: url, options: .atomic) }.value
                } catch { self.showFailure(error.localizedDescription) }
            }
        }
    }
}
