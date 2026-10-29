import AppKit
import Combine
import UniformTypeIdentifiers
import SharedDomain

@MainActor
final class DiagnosticsController: NativeFormController {
    private let state: AppState
    private let details = NativeUI.label("")
    private var subscription: AnyCancellable?
    private var isExporting = false

    init(state: AppState) { self.state = state; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func buildForm() {
        NativeUI.section("Sync", in: stack)
        details.isSelectable = true
        stack.addArrangedSubview(details)
        let verbose = ActionButton("Verbose logging", checkbox: true) { button in UserDefaults.standard.set(button.state == .on, forKey: "verboseLogging") }
        verbose.state = UserDefaults.standard.bool(forKey: "verboseLogging") ? .on : .off
        stack.addArrangedSubview(verbose)
        stack.addArrangedSubview(ActionButton("Export Diagnostics…") { [weak self] _ in self?.export() })
        NativeUI.section("Maintenance", in: stack)
        stack.addArrangedSubview(ActionButton("Rebuild Search Index") { [weak self] _ in
            guard let self else { return }; Task { await self.state.rebuildIndex() }
        })
        stack.addArrangedSubview(ActionButton("Reset File Provider…") { [weak self] _ in
            guard let self else { return }
            NativeUI.confirm(in: self.view.window, title: "Reset File Provider?",
                             message: "Findle will register its Finder location again. Downloaded Moodle files may need to be downloaded again. Your personal files are preserved.",
                             actionTitle: "Reset") { Task { await self.state.resetProvider() } }
        })
        subscription = state.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        let last = state.lastSyncDate?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
        details.stringValue = "Last sync: \(last)\nDatabase: \(state.databaseFilePath ?? "Unavailable")"
        if let error = state.errorMessage { details.stringValue += "\n\(error)" }
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
                } catch { self.details.stringValue = error.localizedDescription }
            }
        }
    }
}
