import AppKit

@MainActor
final class SyncSetupController: SetupStepController {
    private let progress = NSProgressIndicator()
    private let header = SetupStepHeader(title: "First sync", detail: "Files download when opened.")
    private let summary = SetupCourseSummaryView(frame: .zero)
    private var summaryGroup: SetupFormGroup?
    private var finishWithoutSyncingButton: ActionButton?

    override func buildContent() {
        addFullWidth(header)
        let group = SetupFormGroup([summary])
        summaryGroup = group
        addFullWidth(group)
        progress.style = .bar
        progress.isIndeterminate = true
        progress.isHidden = true
        stack.addArrangedSubview(progress)
        progress.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let skip = ActionButton("Finish Without Syncing") { [weak self] _ in
            self?.navigator?.resetButton()
            self?.navigator?.setButtonLabel("Finish")
            self?.navigator?.setContinueEnabled(true)
            self?.finishWithoutSyncingButton?.isHidden = true
        }
        finishWithoutSyncingButton = skip
        stack.addArrangedSubview(skip)
    }

    override func prepareForPresentation() {
        let courses = state.courses.filter(\.isSyncEnabled)
        let count = courses.count
        finishWithoutSyncingButton?.isHidden = count == 0
        let selection = count == 1 ? "1 course selected." : "\(count) courses selected."
        header.update(title: "First sync", detail: "\(selection) Files download when opened.")
        summary.show(courses)
        summaryGroup?.isHidden = courses.isEmpty
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
                    self.header.update(title: "Ready in Finder", detail: "Open a file to download it.")
                    self.message.stringValue = ""
                    self.finishWithoutSyncingButton?.isHidden = true
                    self.navigator?.setButtonLabel("Finish")
                }
            }
        }
        navigator?.setContinueEnabled(true)
    }
}
