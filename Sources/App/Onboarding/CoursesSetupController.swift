import AppKit
import Combine

@MainActor
final class CoursesSetupController: SetupStepController {
    private var selection: CourseSelectionView!
    private let selected = NativeUI.label("", secondary: true)
    private var subscription: AnyCancellable?

    override var scrollsBody: Bool { false }

    override func buildContent() {
        stack.spacing = 12
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byTruncatingTail
        let site = session.site ?? state.currentSite
        let institution = SetupContextView(image: SetupAppearance.symbol("globe"),
                                          title: site?.displayName ?? "Your university",
                                          detail: "", imageSize: 24, titleSize: 15)
        addFullWidth(institution)
        stack.setCustomSpacing(12, after: institution)
        selection = CourseSelectionView(state: state)
        addFullWidth(selection)
        selection.isHidden = state.courses.isEmpty
        let height = selection.heightAnchor.constraint(equalToConstant: 240)
        height.priority = .defaultHigh
        height.isActive = true
        let refresh = ActionButton("Refresh Courses") { [weak self] _ in self?.loadCourses() }
        let footer = NativeUI.stack([selected, NSView(), refresh], spacing: 12, horizontal: true)
        addFullWidth(footer)
        subscription = state.$courses.sink { [weak self] courses in
            self?.selected.isHidden = courses.isEmpty
            self?.selected.stringValue = "\(courses.filter(\.isSyncEnabled).count) of \(courses.count) selected"
        }
    }

    override func prepareForPresentation() {
        state.activateAfterOnboarding()
        loadCourses()
    }

    private func loadCourses() {
        work?.cancel()
        navigator?.setContinueEnabled(false)
        message.stringValue = "Loading courses…"
        work = Task { [weak self] in
            guard let self else { return }
            await self.state.loadCourses()
            guard !Task.isCancelled else { return }
            self.selection.reload()
            self.selection.isHidden = self.state.courses.isEmpty
            self.message.stringValue = self.state.errorMessage ?? (self.state.courses.isEmpty ? "No courses returned. You can check again in Settings." : "")
            self.navigator?.setContinueEnabled(true)
        }
    }
}
