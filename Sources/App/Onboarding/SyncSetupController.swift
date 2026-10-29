import AppKit

@MainActor
final class SyncSetupController: SetupStepController {
    private let progress = NSProgressIndicator()
    private let context = SetupContextView(image: SetupAppearance.symbol("arrow.down.document"),
                                          title: "", detail: "Files download when opened.")
    private let summary = SetupCourseSummaryView(frame: .zero)

    override func buildContent() {
        addFullWidth(context)
        stack.setCustomSpacing(24, after: context)
        addFullWidth(summary)
        progress.style = .bar
        progress.isIndeterminate = true
        progress.isHidden = true
        stack.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.addArrangedSubview(ActionButton("Finish Without Syncing") { [weak self] _ in
            self?.navigator?.resetButton()
            self?.navigator?.setButtonLabel("Finish")
            self?.navigator?.setContinueEnabled(true)
        })
    }

    override func prepareForPresentation() {
        let courses = state.courses.filter(\.isSyncEnabled)
        let count = courses.count
        context.update(title: count == 1 ? "1 course selected" : "\(count) courses selected",
                       detail: "Files download when opened.", image: SetupAppearance.symbol("arrow.down.document"))
        summary.show(courses)
        message.stringValue = count == 0 ? "No courses selected. You can choose them in Settings." : ""
        if count == 0 {
            navigator?.setButtonLabel("Finish")
        } else {
            navigator?.setButtonAction(label: "Sync Courses") { [weak self] in
                guard let self else { return }
                self.progress.isHidden = false
                self.progress.startAnimation(nil)
                self.message.stringValue = "Syncing courses…"
                await self.state.syncAll()
                guard !Task.isCancelled else { return }
                self.progress.stopAnimation(nil)
                self.progress.isHidden = true
                if case .error(let error) = self.state.syncStatus {
                    self.message.stringValue = error
                } else {
                    self.context.update(title: "Ready in Finder", detail: "Open a file to download.",
                                        image: SetupAppearance.symbol("checkmark.circle.fill"))
                    self.message.stringValue = ""
                    self.navigator?.setButtonLabel("Finish")
                }
            }
        }
        navigator?.setContinueEnabled(true)
    }
}
