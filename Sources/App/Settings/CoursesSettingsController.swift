import AppKit
import Combine

@MainActor
final class CoursesSettingsController: NSViewController {
    private let state: AppState
    private let status = NativeUI.label("", secondary: true)
    private var subscription: AnyCancellable?

    init(state: AppState) { self.state = state; super.init(nibName: nil, bundle: nil) }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NativeSurface()
        let courses = CourseSelectionView(state: state)
        let refresh = ActionButton("Refresh Courses") { [weak self] button in
            guard let self else { return }
            button.isEnabled = false
            Task { await self.state.loadCourses(); button.isEnabled = true }
        }
        let sync = ActionButton("Sync Now") { [weak self] _ in
            guard let self else { return }; Task { await self.state.syncAll() }
        }
        let open = ActionButton("Open in Finder") { [weak self] _ in
            guard let self else { return }; Task { await self.state.openFileProviderInFinder() }
        }
        let actions = NativeUI.stack([refresh, sync, open], spacing: 8, horizontal: true)
        let stack = NativeUI.stack([status, courses, actions], spacing: 16)
        NativeUI.pin(stack, in: view, inset: 24)
        courses.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        subscription = state.objectWillChange.sink { [weak self] in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
        refreshStatus()
    }

    private func refreshStatus() {
        switch state.syncStatus {
        case .syncing: status.stringValue = state.syncProgressDetail.map { "Syncing \($0.courseName)…" } ?? "Syncing…"
        case .error(let error): status.stringValue = error
        default: status.stringValue = "\(state.courses.filter(\.isSyncEnabled).count) of \(state.courses.count) courses selected"
        }
    }
}
