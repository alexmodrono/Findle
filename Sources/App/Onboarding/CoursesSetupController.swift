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
        addFullWidth(SetupStepHeader(title: "Choose your courses", detail: site?.displayName ?? "Your university"))
        selection = CourseSelectionView(state: state)
        addFullWidth(selection)
        selection.isHidden = state.courses.isEmpty
        // The list takes whatever height the page leaves free.
        selection.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let fill = stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        fill.priority = .defaultHigh
        fill.isActive = true
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
