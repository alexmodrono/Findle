import AppKit
import Combine
import SwiftUI
import SharedDomain

/// AppKit owns the panel; this adapter publishes cached display data to SwiftUI.
@MainActor
final class CompanionViewController: NSViewController {
    var onToggleMode: (@MainActor () -> Void)?
    var mode: FinderPanelPlacement.Mode { presentation.mode }
    let presentation = CompanionPresentation()
    private let state: AppState
    private let openSettings: @MainActor () -> Void
    private var course: MoodleCourse?
    private var subscription: AnyCancellable?
    private var refreshTask: Task<Void, Never>?

    init(state: AppState, openSettings: @escaping @MainActor () -> Void) {
        self.state = state
        self.openSettings = openSettings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let actions = CompanionActions(
            toggleMode: { [weak self] in self?.onToggleMode?() },
            sync: { [weak self] in self?.sync() },
            openMoodle: { [weak self] in self?.openMoodle() },
            openSettings: openSettings,
            openNode: { [weak self] in self?.open($0) }
        )
        let hosting = CompanionHostingView(rootView: CompanionView(presentation: presentation, actions: actions))
        // Finder placement is the only source of window dimensions and behavior.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.sceneBridgingOptions = []
        view = hosting
        subscription = state.objectWillChange.sink { [weak self] in
            self?.refreshTask?.cancel()
            self?.refreshTask = Task { @MainActor [weak self] in
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func setMode(_ mode: FinderPanelPlacement.Mode, canExpand: Bool = true, attachedOnRight: Bool = true,
                 width: CGFloat? = nil, animated: Bool = false) {
        presentation.canExpand = canExpand
        presentation.attachedOnRight = attachedOnRight
        if mode == .expanded, let width { presentation.expandedWidth = width }
        withAnimation(CompanionMotion.contentTransition(animated: animated)) {
            presentation.mode = mode
        }
    }

    func show(course: MoodleCourse?) {
        let changed = self.course?.id != course?.id || self.course?.siteID != course?.siteID
        self.course = course
        let wasLoaded = isViewLoaded
        _ = view
        if changed || !wasLoaded || !presentation.hasSnapshot { refresh() }
    }

    private func refresh() {
        if let current = course {
            course = state.courses.first { $0.id == current.id && $0.siteID == current.siteID }
        }
        presentation.title = course?.fullName ?? state.currentSite?.displayName ?? "Findle"
        let shortName = course?.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        presentation.shortTitle = shortName.flatMap { $0.isEmpty ? nil : $0 } ?? presentation.title
        let enabledCourses = state.courses.filter(\.isSyncEnabled)
        presentation.subtitle = course == nil ? "\(enabledCourses.count) courses selected" : state.currentSite?.displayName ?? ""
        presentation.hasCourse = course != nil
        if let course {
            presentation.isSyncing = state.courseSyncStates[course.id] == .syncing
            presentation.canSync = course.isSyncEnabled && !presentation.isSyncing
            presentation.lastSynced = state.courseContents(for: course).lastSynced
        } else {
            if case .syncing = state.syncStatus { presentation.isSyncing = true } else { presentation.isSyncing = false }
            presentation.canSync = !enabledCourses.isEmpty && !presentation.isSyncing
            presentation.lastSynced = state.lastSyncDate
        }
        presentation.sessionExpired = state.sessionExpired
        presentation.errorMessage = state.sessionExpired ? "Your session expired. Reconnect in Settings." : state.errorMessage
        if state.sessionExpired { presentation.canSync = false }
        if let course {
            presentation.emptyMessage = course.isSyncEnabled
                ? "Sync this course to load its contents."
                : "Enable this course in Settings to sync its files."
        } else { presentation.emptyMessage = "Choose courses in Settings." }
        let nodes = course.map { state.companionNodes(for: $0) }
            ?? enabledCourses.map { CompanionNode($0.fullName, destination: .course($0.id)) }
        let contextID = "\(state.currentSite?.id ?? "")/\(course.map { String($0.id) } ?? "root")"
        presentation.replaceNodes(nodes, contextID: contextID)
    }

    private func sync() {
        guard presentation.canSync else { return }
        let course = course
        Task { [state] in
            if let course { _ = await state.syncCourse(course) } else { await state.syncAll() }
        }
    }

    private func openMoodle() {
        guard let site = state.currentSite else { return }
        var components = URLComponents(url: site.baseURL, resolvingAgainstBaseURL: false)
        if let course {
            components = URLComponents(url: site.baseURL.appendingPathComponent("course/view.php"), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "id", value: String(course.id))]
        }
        if let url = components?.url { NSWorkspace.shared.open(url) }
    }

    private func open(_ node: CompanionNode) {
        switch node.destination {
        case .item(let id): Task { [state] in await state.openCompanionItem(id) }
        case .web(let url): NSWorkspace.shared.open(url)
        case .course(let id):
            if let course = state.courses.first(where: { $0.id == id }) {
                Task { [state] in await state.openFileProviderInFinder(selecting: course) }
            }
        case .none: presentation.toggleExpansion(node)
        }
    }
}
